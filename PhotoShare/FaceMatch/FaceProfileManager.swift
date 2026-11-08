import CryptoKit
import Foundation
import Supabase
import UIKit

/// Your face reference photos, end-to-end encrypted.
///
/// The photos are sealed on-device with one random key and uploaded as `<uid>/<n>.enc`. That key is wrapped to
/// your own public key (so another device of yours can recover it) and to each friend's public key, as rows of
/// `face_profile_keys`. The server holds ciphertext and wrapped keys only. Profiles uploaded before encryption
/// (`<uid>/<n>.jpg`) stay readable until `syncKeys` re-encrypts them.
struct FaceProfileManager: Sendable {
    enum FaceProfileError: LocalizedError {
        case noKeypair
        case keyNotShared
        case undecryptable

        var errorDescription: String? {
            switch self {
            case .noKeypair: "This phone couldn't read your encryption key."
            case .keyNotShared: "They haven't shared their face profile with you yet. It arrives the next time they open PhotoShare."
            case .undecryptable: "Their face profile changed while loading. Try again in a moment."
            }
        }
    }

    private let bucket = "face-profiles"

    // Storage paths are case-sensitive and the bucket RLS compares the first folder to the
    // lowercase auth.uid()::text, so folders must be the lowercase UUID (UUID.uuidString is uppercase).
    private func folder(_ userId: UUID) -> String { userId.uuidString.lowercased() }

    // MARK: - Owner

    func enable(photos: [UIImage], for userId: UUID) async throws {
        try await upload(images: photos, for: userId)

        try await supabase
            .from("profiles")
            .update(["face_profile_enabled": true])
            .eq("id", value: userId)
            .execute()

        // Friends who are already connected get the new key now rather than at the next app launch.
        let friends: [Friend] = (try? await supabase.rpc("list_friends").execute().value) ?? []
        await Self.syncKeys(userId: userId, friendIds: friends.map(\.friendId))
    }

    func disable(for userId: UUID) async throws {
        try await deleteStorageFiles(for: userId)
        try await supabase.from("face_profile_keys").delete().eq("owner_id", value: userId).execute()

        try await supabase
            .from("profiles")
            .update(["face_profile_enabled": false])
            .eq("id", value: userId)
            .execute()
    }

    /// Seals the photos under a fresh key and replaces the stored set. Friends get the new key from `syncKeys`
    /// (called right after here, and again whenever the app opens).
    private func upload(images: [UIImage], for userId: UUID) async throws {
        guard let privateKey = KeyPairManager.loadOrCreate(for: userId) else { throw FaceProfileError.noKeypair }
        let key = SymmetricKey(size: .bits256)
        var sealed: [Data] = []
        for image in images {
            guard let jpeg = image.jpegData(compressionQuality: 0.85) else { continue }
            sealed.append(try PhotoEncryption.seal(jpeg, using: key))
        }

        // The old key goes first: a friend holding it can't open the new files, and shouldn't open the old ones.
        try await supabase.from("face_profile_keys").delete().eq("owner_id", value: userId).execute()
        try await deleteStorageFiles(for: userId)
        for (index, blob) in sealed.enumerated() {
            try await supabase.storage.from(bucket).upload(
                path: "\(folder(userId))/\(index).enc",
                file: blob,
                options: FileOptions(contentType: "application/octet-stream")
            )
        }
        // Own copy first, so the profile is recoverable from any of your devices even if no friend is reachable.
        try await grant(key, to: [userId: privateKey.publicKey], owner: userId)
    }

    /// Keeps `face_profile_keys` equal to {you} + {current friends who have published a key}: grants new friends,
    /// and re-encrypts a legacy plaintext profile. Cheap when nothing changed; failures
    /// (offline) are retried the next time the app opens or returns to the foreground.
    static func syncKeys(userId: UUID, friendIds: [UUID]) async {
        do { try await FaceProfileManager().sync(userId: userId, friendIds: friendIds) }
        catch { print("[FaceProfile] Key sync failed: \(error)") }
    }

    private func sync(userId: UUID, friendIds: [UUID]) async throws {
        guard let privateKey = KeyPairManager.privateKey(for: userId) else { return }
        let files = try await supabase.storage.from(bucket).list(path: folder(userId))
        guard !files.isEmpty else { return }   // no face profile yet

        let rows = try await keyRows(owner: userId)
        guard let ownRow = rows.first(where: { $0.recipientId == userId }) else {
            // Legacy plaintext profile (or an interrupted replace): download it, then re-encrypt under a fresh key.
            let legacy = files.filter { $0.name.hasSuffix(".jpg") }
            guard !legacy.isEmpty else { return }
            var images: [UIImage] = []
            for file in legacy {
                let data = try await supabase.storage.from(bucket).download(path: "\(folder(userId))/\(file.name)")
                if let image = UIImage(data: data) { images.append(image) }
            }
            guard !images.isEmpty else { return }
            try await upload(images: images, for: userId)
            return try await sync(userId: userId, friendIds: friendIds)
        }
        let key = try PhotoEncryption.unwrap(Data(base64Encoded: ownRow.wrappedKey) ?? Data(), with: privateKey)

        let have = Set(rows.map(\.recipientId))
        let missing = friendIds.filter { !have.contains($0) }
        if !missing.isEmpty {
            let keys = try await KeyPairManager.publicKeys(for: missing)   // friends without a key are picked up later
            try await grant(key, to: keys, owner: userId)
        }
        // Revocation is server-side: unfriending deletes the friend's key row (trigger on friendships).
    }

    private func grant(_ key: SymmetricKey, to recipients: [UUID: P256.KeyAgreement.PublicKey], owner: UUID) async throws {
        guard !recipients.isEmpty else { return }
        let rows = try recipients.map { id, publicKey in
            KeyRow(ownerId: owner, recipientId: id, wrappedKey: try PhotoEncryption.wrap(key, to: publicKey).base64EncodedString())
        }
        try await supabase.from("face_profile_keys").upsert(rows).execute()
    }

    private func keyRows(owner: UUID) async throws -> [KeyRow] {
        try await supabase.from("face_profile_keys").select().eq("owner_id", value: owner).execute().value
    }

    // MARK: - Friend

    /// Whether `viewerId` can read `friendId`'s face profile right now, and which version it is. The version changes
    /// whenever the friend replaces their photos (a new key is granted), so enrollment knows when to redo itself.
    enum Availability: Equatable, Sendable {
        case none                       // no reference photos uploaded
        case waitingForKey              // encrypted, but they haven't granted this viewer a key yet (they open the app next)
        case available(version: String)
    }

    func availability(of friendId: UUID, viewer viewerId: UUID) async throws -> Availability {
        let files = try await supabase.storage.from(bucket).list(path: folder(friendId))
        guard !files.isEmpty else { return .none }
        let encrypted = files.filter { $0.name.hasSuffix(".enc") }
        if encrypted.isEmpty {
            // Legacy plaintext profile: any re-upload changes the object ids.
            let version = files.map { "\($0.name)#\(String(describing: $0.id))" }.sorted().joined(separator: ",")
            return .available(version: "legacy:" + version)
        }
        let rows: [KeyRow] = try await supabase.from("face_profile_keys").select()
            .eq("owner_id", value: friendId)
            .eq("recipient_id", value: viewerId)
            .execute().value
        guard let row = rows.first else { return .waitingForKey }
        return .available(version: "key:" + (row.createdAt ?? row.wrappedKey.suffix(16).description))
    }

    /// Decrypts `friendId`'s reference photos with the key they granted to `viewerId`. Profiles uploaded before
    /// encryption are plain JPEGs and pass through.
    func downloadPhotos(for friendId: UUID, viewer viewerId: UUID) async throws -> [UIImage] {
        let files = try await supabase.storage.from(bucket).list(path: folder(friendId))
        let encrypted = files.filter { $0.name.hasSuffix(".enc") }
        let names = (encrypted.isEmpty ? files : encrypted).map(\.name)

        var key: SymmetricKey?
        if !encrypted.isEmpty {
            let rows: [KeyRow] = try await supabase.from("face_profile_keys").select()
                .eq("owner_id", value: friendId)
                .eq("recipient_id", value: viewerId)
                .execute().value
            guard let row = rows.first, let wrapped = Data(base64Encoded: row.wrappedKey) else { throw FaceProfileError.keyNotShared }
            guard let privateKey = KeyPairManager.privateKey(for: viewerId) else { throw FaceProfileError.noKeypair }
            key = try PhotoEncryption.unwrap(wrapped, with: privateKey)
        }

        var images: [UIImage] = []
        for name in names {
            var data = try await supabase.storage.from(bucket).download(path: "\(folder(friendId))/\(name)")
            if let key {
                do { data = try PhotoEncryption.open(blob: data, key: key) }
                catch { throw FaceProfileError.undecryptable }
            }
            if let image = UIImage(data: data) { images.append(image) }
        }
        return images
    }

    private func deleteStorageFiles(for userId: UUID) async throws {
        let files = try await supabase.storage.from(bucket).list(path: folder(userId))
        guard !files.isEmpty else { return }
        let paths = files.map { "\(folder(userId))/\($0.name)" }
        try await supabase.storage.from(bucket).remove(paths: paths)
    }
}

private struct KeyRow: Codable {
    let ownerId: UUID
    let recipientId: UUID
    let wrappedKey: String
    var createdAt: String? = nil   // read only; nil is omitted when granting

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case recipientId = "recipient_id"
        case wrappedKey = "wrapped_key"
        case createdAt = "created_at"
    }
}

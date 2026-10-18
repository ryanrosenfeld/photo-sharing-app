import CryptoKit
import Photos
import Supabase
import UIKit

/// Loads library images at full resolution (shared by auto-share and the review queue).
@MainActor
enum AssetImageLoader {
    static func fullImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// Uploads a photo to storage and records the recipients. The only place a photo leaves the device.
@MainActor
enum ShareUploader {
    enum ShareError: LocalizedError {
        case assetUnavailable
        case encodingFailed
        case recipientsNotReady

        var errorDescription: String? {
            switch self {
            case .assetUnavailable: "That photo is no longer in your library."
            case .encodingFailed: "Couldn't prepare the photo for sending."
            case .recipientsNotReady: "Your friend needs to open PhotoShare once to turn on encryption before they can receive photos."
            }
        }
    }

    /// Used by the review queue: the photo is looked up again by its library identifier at approval time.
    static func send(assetId: String, senderId: UUID, recipientIds: [UUID]) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
              let image = await AssetImageLoader.fullImage(for: asset)
        else { throw ShareError.assetUnavailable }
        try await upload(image: image, asset: asset, senderId: senderId, recipientIds: recipientIds)
    }

    static func upload(image: UIImage, asset: PHAsset, senderId: UUID, recipientIds: [UUID]) async throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw ShareError.encodingFailed }

        // Photos are end-to-end encrypted: one sealed blob, with its key wrapped to each recipient's public key.
        // A friend who hasn't published a key yet (hasn't opened the encryption-capable app) is skipped, never sent in the clear.
        let publicKeys = try await KeyPairManager.publicKeys(for: recipientIds)
        let reachable = recipientIds.filter { publicKeys[$0] != nil }
        if reachable.count < recipientIds.count {
            print("[Share] Skipping \(recipientIds.count - reachable.count) recipient(s) without an encryption key.")
        }
        guard !reachable.isEmpty else { throw ShareError.recipientsNotReady }
        let sealed = try PhotoEncryption.seal(data)
        var wrappedKeys: [UUID: String] = [:]
        for id in reachable {
            wrappedKeys[id] = try PhotoEncryption.wrap(sealed.key, to: publicKeys[id]!).base64EncodedString()
        }

        let storagePath = "photos/\(UUID().uuidString).enc"
        try await supabase.storage
            .from("photos")
            .upload(path: storagePath, file: sealed.blob, options: FileOptions(contentType: "application/octet-stream"))

        let inserted: InsertedPhoto = try await supabase
            .from("photos")
            .insert(NewPhoto(
                senderId: senderId,
                storagePath: storagePath,
                takenAt: asset.creationDate ?? Date(),
                locationLat: asset.location?.coordinate.latitude,
                locationLng: asset.location?.coordinate.longitude
            ))
            .select("id")
            .single()
            .execute()
            .value

        let isoNow = ISO8601DateFormatter().string(from: Date())
        let recipients = reachable.map {
            NewRecipient(photoId: inserted.id, recipientId: $0, deliveredAt: isoNow, wrappedKey: wrappedKeys[$0]!)
        }
        try await supabase.from("photo_recipients").insert(recipients).execute()
    }
}

private struct NewPhoto: Encodable {
    let senderId: UUID
    let storagePath: String
    let takenAt: Date
    let locationLat: Double?
    let locationLng: Double?

    enum CodingKeys: String, CodingKey {
        case senderId = "sender_id"
        case storagePath = "storage_path"
        case takenAt = "taken_at"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
    }
}

private struct InsertedPhoto: Decodable {
    let id: UUID
}

private struct NewRecipient: Encodable {
    let photoId: UUID
    let recipientId: UUID
    let deliveredAt: String
    let wrappedKey: String

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case recipientId = "recipient_id"
        case deliveredAt = "delivered_at"
        case wrappedKey = "wrapped_key"
    }
}

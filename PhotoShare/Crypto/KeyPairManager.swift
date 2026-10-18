import CryptoKit
import Foundation
import Security
import Supabase

/// The user's P-256 keypair for receiving photos. The private key lives in the Keychain (synced through
/// iCloud Keychain so a second device can read the same photos) and never leaves the device otherwise;
/// the public key is published in `profiles.public_key` so friends can encrypt to it.
enum KeyPairManager {
    private static let service = "com.photoshare.e2ee.p256"

    // MARK: - Keychain

    static func privateKey(for userId: UUID) -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userId.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    @discardableResult
    private static func store(_ key: P256.KeyAgreement.PrivateKey, for userId: UUID) -> Bool {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userId.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrSynchronizable as String: true,
        ]
        if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return true }
        // Unsigned/simulator builds can refuse synchronizable items; a local-only key still works on this device.
        attributes[kSecAttrSynchronizable as String] = false
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Returns the user's key, creating it on first use.
    static func loadOrCreate(for userId: UUID) -> P256.KeyAgreement.PrivateKey? {
        if let existing = privateKey(for: userId) { return existing }
        let fresh = P256.KeyAgreement.PrivateKey()
        return store(fresh, for: userId) ? fresh : nil
    }

    // MARK: - Publishing

    /// Makes sure this account has a keypair and that the server holds the matching public key.
    /// Cheap when nothing changed; failures (offline) are retried on the next launch.
    static func ensurePublished(for profile: UserProfile) async {
        guard let key = loadOrCreate(for: profile.id) else {
            print("[Crypto] Could not create or read the keypair in the Keychain.")
            return
        }
        let encoded = PhotoEncryption.encode(key.publicKey)
        guard profile.publicKey != encoded else { return }
        do {
            try await supabase.from("profiles").update(["public_key": encoded]).eq("id", value: profile.id).execute()
        } catch {
            print("[Crypto] Public key upload failed: \(error)")
        }
    }

    /// Public keys for the given users. Users who haven't published one yet are absent from the result.
    static func publicKeys(for userIds: [UUID]) async throws -> [UUID: P256.KeyAgreement.PublicKey] {
        struct Row: Decodable { let id: UUID; let publicKey: String?
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public_key" } }
        let rows: [Row] = try await supabase.from("profiles").select("id, public_key").in("id", values: userIds).execute().value
        var keys: [UUID: P256.KeyAgreement.PublicKey] = [:]
        for row in rows {
            if let encoded = row.publicKey, let key = try? PhotoEncryption.decodePublicKey(encoded) { keys[row.id] = key }
        }
        return keys
    }
}

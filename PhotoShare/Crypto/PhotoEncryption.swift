import CryptoKit
import Foundation

/// Hybrid (ECIES-style) photo encryption.
///
/// A photo is sealed once with a random 256-bit content key (AES-256-GCM), so a photo for N friends is one
/// uploaded blob. The content key is then wrapped separately to each recipient's P-256 public key:
/// ephemeral ECDH -> HKDF-SHA256 -> AES-256-GCM. The server stores the blob and the wrapped keys and can open neither.
enum PhotoEncryption {
    enum CryptoError: LocalizedError {
        case malformedWrappedKey
        case malformedPublicKey

        var errorDescription: String? {
            switch self {
            case .malformedWrappedKey: "The photo's key is damaged."
            case .malformedPublicKey: "A friend's encryption key is invalid."
            }
        }
    }

    private static let wrapInfo = Data("photoshare/photo-key/v1".utf8)
    /// ANSI X9.63 uncompressed P-256 point: 0x04 || X || Y.
    private static let ephemeralKeyLength = 65

    // MARK: - Content

    static func seal(_ plaintext: Data) throws -> (blob: Data, key: SymmetricKey) {
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(plaintext, using: key)
        return (box.combined!, key)   // combined is non-nil for the default 12-byte nonce
    }

    static func open(blob: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key)
    }

    // MARK: - Key wrapping

    static func wrap(_ contentKey: SymmetricKey, to recipient: P256.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let kek = try wrappingKey(
            secret: ephemeral.sharedSecretFromKeyAgreement(with: recipient),
            ephemeral: ephemeral.publicKey,
            recipient: recipient
        )
        let sealed = try AES.GCM.seal(contentKey.withUnsafeBytes { Data($0) }, using: kek)
        return ephemeral.publicKey.x963Representation + sealed.combined!
    }

    static func unwrap(_ wrapped: Data, with privateKey: P256.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        guard wrapped.count > ephemeralKeyLength else { throw CryptoError.malformedWrappedKey }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: wrapped.prefix(ephemeralKeyLength))
        let kek = try wrappingKey(
            secret: privateKey.sharedSecretFromKeyAgreement(with: ephemeral),
            ephemeral: ephemeral,
            recipient: privateKey.publicKey
        )
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped.dropFirst(ephemeralKeyLength)), using: kek)
        guard raw.count == 32 else { throw CryptoError.malformedWrappedKey }
        return SymmetricKey(data: raw)
    }

    /// Binds the derived key to both public keys so a wrapped key can't be replayed against another recipient.
    private static func wrappingKey(
        secret: SharedSecret,
        ephemeral: P256.KeyAgreement.PublicKey,
        recipient: P256.KeyAgreement.PublicKey
    ) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.x963Representation,
            sharedInfo: wrapInfo + recipient.x963Representation,
            outputByteCount: 32
        )
    }

    // MARK: - Public key transport (profiles.public_key)

    static func encode(_ key: P256.KeyAgreement.PublicKey) -> String {
        key.derRepresentation.base64EncodedString()
    }

    static func decodePublicKey(_ base64: String) throws -> P256.KeyAgreement.PublicKey {
        guard let der = Data(base64Encoded: base64) else { throw CryptoError.malformedPublicKey }
        do { return try P256.KeyAgreement.PublicKey(derRepresentation: der) }
        catch { throw CryptoError.malformedPublicKey }
    }
}

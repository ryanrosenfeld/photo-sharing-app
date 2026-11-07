import CryptoKit
import XCTest
@testable import PhotoShare

final class PhotoEncryptionTests: XCTestCase {
    private let photo = Data((0..<4096).map { UInt8($0 % 251) })

    func testSealedBlobIsNotThePlaintextAndRoundTrips() throws {
        let sealed = try PhotoEncryption.seal(photo)
        XCTAssertNotEqual(sealed.blob, photo)
        XCTAssertFalse(sealed.blob.range(of: photo.prefix(64)) != nil, "plaintext must not appear in the blob")
        XCTAssertEqual(try PhotoEncryption.open(blob: sealed.blob, key: sealed.key), photo)
    }

    func testTamperedBlobIsRejected() throws {
        var sealed = try PhotoEncryption.seal(photo)
        sealed.blob[sealed.blob.count / 2] ^= 0x01
        XCTAssertThrowsError(try PhotoEncryption.open(blob: sealed.blob, key: sealed.key))
    }

    func testEachRecipientUnwrapsTheSameContentKey() throws {
        let bob = P256.KeyAgreement.PrivateKey()
        let carol = P256.KeyAgreement.PrivateKey()
        let sealed = try PhotoEncryption.seal(photo)
        let forBob = try PhotoEncryption.wrap(sealed.key, to: bob.publicKey)
        let forCarol = try PhotoEncryption.wrap(sealed.key, to: carol.publicKey)
        XCTAssertNotEqual(forBob, forCarol)
        for (wrapped, key) in [(forBob, bob), (forCarol, carol)] {
            let recovered = try PhotoEncryption.unwrap(wrapped, with: key)
            XCTAssertEqual(try PhotoEncryption.open(blob: sealed.blob, key: recovered), photo)
        }
    }

    func testWrappedKeyOnlyOpensForItsRecipient() throws {
        let bob = P256.KeyAgreement.PrivateKey()
        let mallory = P256.KeyAgreement.PrivateKey()
        let sealed = try PhotoEncryption.seal(photo)
        let forBob = try PhotoEncryption.wrap(sealed.key, to: bob.publicKey)
        XCTAssertThrowsError(try PhotoEncryption.unwrap(forBob, with: mallory))
    }

    func testWrappingIsRandomised() throws {
        let bob = P256.KeyAgreement.PrivateKey()
        let key = SymmetricKey(size: .bits256)
        XCTAssertNotEqual(try PhotoEncryption.wrap(key, to: bob.publicKey), try PhotoEncryption.wrap(key, to: bob.publicKey))
    }

    func testMalformedWrappedKeyThrows() {
        let bob = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try PhotoEncryption.unwrap(Data([1, 2, 3]), with: bob))
    }

    func testPublicKeyTransportRoundTrips() throws {
        let key = P256.KeyAgreement.PrivateKey().publicKey
        XCTAssertEqual(try PhotoEncryption.decodePublicKey(PhotoEncryption.encode(key)).x963Representation, key.x963Representation)
        XCTAssertThrowsError(try PhotoEncryption.decodePublicKey("not base64!"))
    }

    func testKeychainKeyIsStableAcrossLoads() throws {
        let user = UUID()
        let first = try XCTUnwrap(KeyPairManager.loadOrCreate(for: user))
        let second = try XCTUnwrap(KeyPairManager.loadOrCreate(for: user))
        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
        XCTAssertNil(KeyPairManager.privateKey(for: UUID()), "another account has its own key")
    }

    func testFaceProfileSetSharesOneKeyAcrossPhotosAndFriends() throws {
        let owner = P256.KeyAgreement.PrivateKey()
        let friend = P256.KeyAgreement.PrivateKey()
        let stranger = P256.KeyAgreement.PrivateKey()
        let key = SymmetricKey(size: .bits256)
        let faces = [Data("face-0".utf8), Data("face-1".utf8), Data("face-2".utf8)]
        let blobs = try faces.map { try PhotoEncryption.seal($0, using: key) }
        XCTAssertNotEqual(blobs[0], faces[0])

        // The owner (second device) and a friend recover the same key; a stranger cannot.
        for holder in [owner, friend] {
            let recovered = try PhotoEncryption.unwrap(try PhotoEncryption.wrap(key, to: holder.publicKey), with: holder)
            XCTAssertEqual(try blobs.map { try PhotoEncryption.open(blob: $0, key: recovered) }, faces)
        }
        let forFriend = try PhotoEncryption.wrap(key, to: friend.publicKey)
        XCTAssertThrowsError(try PhotoEncryption.unwrap(forFriend, with: stranger))
        // A rotated key (profile replaced) can't open the old files.
        XCTAssertThrowsError(try PhotoEncryption.open(blob: blobs[0], key: SymmetricKey(size: .bits256)))
    }
}

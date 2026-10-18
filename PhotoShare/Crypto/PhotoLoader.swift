import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// Downloads a received photo and decrypts it with the user's private key. Photos shared before E2E
/// encryption (no wrapped key) are plain JPEGs and pass through unchanged.
@MainActor
final class PhotoLoader {
    static let shared = PhotoLoader()

    enum LoadError: LocalizedError {
        case noPrivateKey
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .noPrivateKey: "This photo was encrypted for a different device. Sign in on the device you used when it was sent."
            case .notAnImage: "Could not load photo."
            }
        }
    }

    private let cache = NSCache<NSUUID, UIImage>()

    func imageData(for photo: ReceivedPhoto) async throws -> Data {
        let blob = try await supabase.storage.from("photos").download(path: photo.photos.storagePath)
        guard let wrapped = photo.wrappedKey else { return blob }
        guard let privateKey = KeyPairManager.privateKey(for: photo.recipientId),
              let wrappedData = Data(base64Encoded: wrapped)
        else { throw LoadError.noPrivateKey }
        let key = try PhotoEncryption.unwrap(wrappedData, with: privateKey)
        return try PhotoEncryption.open(blob: blob, key: key)
    }

    func image(for photo: ReceivedPhoto) async throws -> UIImage {
        if let cached = cache.object(forKey: photo.photoId as NSUUID) { return cached }
        guard let image = UIImage(data: try await imageData(for: photo)) else { throw LoadError.notAnImage }
        cache.setObject(image, forKey: photo.photoId as NSUUID)
        return image
    }
}

/// Drop-in for `AsyncImage` that downloads and decrypts a received photo.
struct PhotoImage<Content: View>: View {
    enum Phase {
        case empty
        case success(Image)
        case failure(Error)
    }

    let photo: ReceivedPhoto
    @ViewBuilder let content: (Phase) -> Content
    @State private var phase: Phase = .empty

    var body: some View {
        content(phase)
            .task(id: photo.photoId) {
                do { phase = .success(Image(uiImage: try await PhotoLoader.shared.image(for: photo))) }
                catch { phase = .failure(error) }
            }
    }
}

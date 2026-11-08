import CryptoKit
import ImageIO
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

        var errorDescription: String? {
            switch self {
            case .assetUnavailable: "That photo is no longer in your library."
            case .encodingFailed: "Couldn't prepare the photo for sending."
            }
        }
    }

    /// Used by the review queue: the photo is looked up again by its library identifier at approval time.
    static func send(assetId: String, senderId: UUID, recipientIds: [UUID], pending: PendingShareStore = .shared) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
              let image = await AssetImageLoader.fullImage(for: asset)
        else { throw ShareError.assetUnavailable }
        try await upload(image: image, asset: asset, senderId: senderId, recipientIds: recipientIds, pending: pending)
    }

    /// Friends who haven't published an encryption key yet are never sent the photo in the clear; they are
    /// recorded in `pending` and retried when the app next opens, once their key exists.
    static func upload(image: UIImage, asset: PHAsset, senderId: UUID, recipientIds: [UUID], pending: PendingShareStore = .shared) async throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw ShareError.encodingFailed }

        // Photos are end-to-end encrypted: one sealed blob, with its key wrapped to each recipient's public key.
        let publicKeys = try await KeyPairManager.publicKeys(for: recipientIds)
        let reachable = recipientIds.filter { publicKeys[$0] != nil }
        let waiting = recipientIds.filter { publicKeys[$0] == nil }
        if !waiting.isEmpty {
            print("[Share] \(waiting.count) recipient(s) have no encryption key yet; will retry.")
            pending.add(assetId: asset.localIdentifier, recipientIds: waiting)
        }
        guard !reachable.isEmpty else { return }
        let sealed = try PhotoEncryption.seal(data)
        var wrappedKeys: [UUID: String] = [:]
        for id in reachable {
            wrappedKeys[id] = try PhotoEncryption.wrap(sealed.key, to: publicKeys[id]!).base64EncodedString()
        }

        let name = UUID().uuidString
        let storagePath = "photos/\(name).enc"
        try await supabase.storage
            .from("photos")
            .upload(path: storagePath, file: sealed.blob, options: FileOptions(contentType: "application/octet-stream"))

        // A small encrypted thumbnail (same content key) so receivers can paint the first image without downloading the
        // full photo. Best effort: without it, receivers just load the full photo.
        var thumbPath: String?
        if let thumb = Self.thumbnailJPEG(from: data), let sealedThumb = try? PhotoEncryption.seal(thumb, with: sealed.key) {
            let path = "photos/\(name).thumb.enc"
            do {
                try await supabase.storage
                    .from("photos")
                    .upload(path: path, file: sealedThumb, options: FileOptions(contentType: "application/octet-stream"))
                thumbPath = path
            } catch {
                print("[Share] thumbnail upload failed, continuing without: \(error)")
            }
        }

        let inserted: InsertedPhoto = try await supabase
            .from("photos")
            .insert(NewPhoto(
                senderId: senderId,
                storagePath: storagePath,
                thumbPath: thumbPath,
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

    /// ~800px JPEG for the polaroid stack (matches the receiver's thumbnail size), orientation baked in.
    nonisolated static func thumbnailJPEG(from jpeg: Data, maxPixelSize: Int = 800) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }
}

private struct NewPhoto: Encodable {
    let senderId: UUID
    let storagePath: String
    let thumbPath: String?
    let takenAt: Date
    let locationLat: Double?
    let locationLng: Double?

    enum CodingKeys: String, CodingKey {
        case senderId = "sender_id"
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
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

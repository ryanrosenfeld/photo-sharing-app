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
    static func send(assetId: String, senderId: UUID, recipientIds: [UUID]) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
              let image = await AssetImageLoader.fullImage(for: asset)
        else { throw ShareError.assetUnavailable }
        try await upload(image: image, asset: asset, senderId: senderId, recipientIds: recipientIds)
    }

    static func upload(image: UIImage, asset: PHAsset, senderId: UUID, recipientIds: [UUID]) async throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw ShareError.encodingFailed }
        let storagePath = "photos/\(UUID().uuidString).jpg"

        try await supabase.storage
            .from("photos")
            .upload(path: storagePath, file: data, options: FileOptions(contentType: "image/jpeg"))

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
        let recipients = recipientIds.map {
            NewRecipient(photoId: inserted.id, recipientId: $0, deliveredAt: isoNow)
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

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case recipientId = "recipient_id"
        case deliveredAt = "delivered_at"
    }
}

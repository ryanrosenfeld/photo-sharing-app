import Photos
import Supabase
import UIKit

// Orchestrates the full auto-share loop:
//   1. Fetch new camera-roll photos since last run
//   2. Detect faces in each photo (off main thread)
//   3. Match against enrolled friends' embeddings
//   4. Upload matched photos to Supabase Storage + create DB records
//
// Owned by MainTabView so it lives for the session lifetime.
@MainActor
final class AutoShareProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var lastError: String?

    let libraryManager = PhotoLibraryManager()

    private let detector = FaceDetector()
    private let store = FaceEnrollmentStore()

    // MARK: - Entry point

    func processNewPhotos(userId: UUID, outgoingLinks: [OutgoingLink]) async {
        guard !isProcessing else {
            print("[AutoShare] Already processing, skipping.")
            return
        }

        let enrolledLinks = outgoingLinks.filter { store.hasEnrollment(for: $0.recipientId) }
        print("[AutoShare] Outgoing links: \(outgoingLinks.count), enrolled: \(enrolledLinks.count)")
        guard !enrolledLinks.isEmpty else { return }

        let newAssets = libraryManager.fetchNewAssets()
        print("[AutoShare] New assets since \(libraryManager.lastProcessedDate): \(newAssets.count)")
        guard !newAssets.isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        for asset in newAssets {
            let date = asset.creationDate.map { "\($0)" } ?? "unknown"
            print("[AutoShare] Processing asset from \(date)")

            guard let image = await loadFullImage(from: asset) else {
                print("[AutoShare]   ↳ Could not load image, skipping.")
                continue
            }

            let faceEmbeddings: [[Float]]
            do {
                faceEmbeddings = try await Task.detached(priority: .userInitiated) { [detector, image] in
                    try detector.allFaceEmbeddings(in: image)
                }.value
                print("[AutoShare]   ↳ Detected \(faceEmbeddings.count) face(s).")
            } catch {
                print("[AutoShare]   ↳ Face detection error: \(error)")
                continue
            }
            guard !faceEmbeddings.isEmpty else { continue }

            let matchedIds: [UUID] = enrolledLinks.compactMap { link in
                guard let enrolled = store.load(for: link.recipientId) else { return nil }
                let matched = detector.isMatch(photoFaces: faceEmbeddings, enrolled: enrolled)
                print("[AutoShare]   ↳ \(link.recipient.displayName): \(matched ? "MATCH" : "no match")")
                return matched ? link.recipientId : nil
            }

            if !matchedIds.isEmpty {
                print("[AutoShare]   ↳ Uploading for \(matchedIds.count) recipient(s)…")
                await uploadAndShare(image: image, asset: asset, senderId: userId, recipientIds: matchedIds)
                print("[AutoShare]   ↳ Done.")
            }
        }

        libraryManager.lastProcessedDate = Date()
        print("[AutoShare] Finished. lastProcessedDate updated.")
    }

    // MARK: - Image loading

    private func loadFullImage(from asset: PHAsset) async -> UIImage? {
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

    // MARK: - Upload + DB write

    private func uploadAndShare(
        image: UIImage,
        asset: PHAsset,
        senderId: UUID,
        recipientIds: [UUID]
    ) async {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let storagePath = "photos/\(UUID().uuidString).jpg"

        do {
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

        } catch {
            lastError = error.localizedDescription
            print("[AutoShare] Upload/DB error: \(error)")
        }
    }
}

// MARK: - Local Encodable types

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

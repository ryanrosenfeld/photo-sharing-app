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

    func processNewPhotos(userId: UUID, outgoingLinks: [OutgoingLink], review: ReviewQueueStore) async {
        guard !isProcessing else {
            print("[AutoShare] Already processing, skipping.")
            return
        }

        let enrolledLinks = outgoingLinks.filter { !$0.isPaused && store.hasEnrollment(for: $0.recipientId) }
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

            let faceEmbeddings: [FaceEmbedding]
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

            let (sendNow, toReview) = review.settings.partition(matchedIds)

            if !toReview.isEmpty {
                // Held on device: nothing is uploaded until the user approves it in the review queue.
                let recipients = enrolledLinks
                    .filter { toReview.contains($0.recipientId) }
                    .map { ReviewItem.Recipient(id: $0.recipientId, name: $0.recipient.displayName) }
                review.enqueue(assetId: asset.localIdentifier, takenAt: asset.creationDate ?? Date(), recipients: recipients)
                print("[AutoShare]   ↳ Queued for review (\(recipients.count) recipient(s)); not uploaded.")
            }

            if !sendNow.isEmpty {
                print("[AutoShare]   ↳ Uploading for \(sendNow.count) recipient(s)…")
                await uploadAndShare(image: image, asset: asset, senderId: userId, recipientIds: sendNow)
                print("[AutoShare]   ↳ Done.")
            }
        }

        libraryManager.lastProcessedDate = Date()
        print("[AutoShare] Finished. lastProcessedDate updated.")
    }

    // MARK: - Image loading

    private func loadFullImage(from asset: PHAsset) async -> UIImage? {
        await AssetImageLoader.fullImage(for: asset)
    }

    // MARK: - Upload

    private func uploadAndShare(image: UIImage, asset: PHAsset, senderId: UUID, recipientIds: [UUID]) async {
        do {
            try await ShareUploader.upload(image: image, asset: asset, senderId: senderId, recipientIds: recipientIds)
        } catch {
            lastError = error.localizedDescription
            print("[AutoShare] Upload/DB error: \(error)")
        }
    }
}

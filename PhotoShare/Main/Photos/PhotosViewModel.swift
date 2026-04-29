import Foundation
import UIKit
import Photos

@MainActor
final class PhotosViewModel: ObservableObject {
    @Published var photos: [ReceivedPhoto] = []
    @Published var isLoading = false
    @Published var error: String?

    func load(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await supabase
                .from("photo_recipients")
                .select("*, photos(*, sender:profiles!sender_id(display_name, avatar_url))")
                .eq("recipient_id", value: userId)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markViewed(_ photo: ReceivedPhoto) async {
        guard photo.viewedAt == nil else { return }
        try? await supabase
            .from("photo_recipients")
            .update(["viewed_at": ISO8601DateFormatter().string(from: Date())])
            .eq("photo_id", value: photo.photoId)
            .eq("recipient_id", value: photo.recipientId)
            .execute()
    }

    func saveToLibrary(_ photo: ReceivedPhoto) async {
        guard !photo.isSaved, let url = photo.photos.publicURL else { return }

        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                self.error = "Photo library access denied. Enable it in Settings."
                return
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                self.error = "Could not load photo."
                return
            }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }

            try await supabase
                .from("photo_recipients")
                .update(["saved_at": ISO8601DateFormatter().string(from: Date())])
                .eq("photo_id", value: photo.photoId)
                .eq("recipient_id", value: photo.recipientId)
                .execute()

            if let idx = photos.firstIndex(where: { $0.id == photo.id }) {
                photos[idx].savedAt = Date()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

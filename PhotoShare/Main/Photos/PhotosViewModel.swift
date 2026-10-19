import Foundation
import UIKit
import Photos

@MainActor
final class PhotosViewModel: ObservableObject {
    @Published var photos: [ReceivedPhoto] = []
    @Published var isLoading = false
    @Published var error: String?
    /// True when the last load failed (drives the retry state while there is nothing to show).
    @Published var loadFailed = false

    func load(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        loadFailed = false
        do {
            photos = try await supabase
                .from("photo_recipients")
                .select("*, photos(*, sender:profiles!sender_id(display_name, avatar_url))")
                .eq("recipient_id", value: userId)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch where Self.isCancellation(error) {
            // Pull to refresh cancelled by SwiftUI (view update mid-refresh): nothing failed, nothing to show.
        } catch {
            loadFailed = true
            // Refreshing with content on screen: keep the content and tell the user. Otherwise the retry state says it.
            if !photos.isEmpty { self.error = error.localizedDescription }
        }
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func saveAll(_ batch: [ReceivedPhoto]) async {
        for photo in batch where !photo.isSaved {
            await saveToLibrary(photo)
            if error != nil { break }   // e.g. library access denied: one alert, not one per photo
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
        guard !photo.isSaved else { return }

        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                self.error = "Photo library access denied. Enable it in Settings."
                return
            }

            let data = try await PhotoLoader.shared.imageData(for: photo)
            guard UIImage(data: data) != nil else {
                self.error = "Could not load photo."
                return
            }

            try await Self.addToLibrary(data)

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

    /// Nonisolated on purpose: PhotoKit runs the change block on its own queue, and a block created inside a
    /// @MainActor method inherits main-actor isolation and traps (Swift 6 executor check) when called there.
    nonisolated private static func addToLibrary(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let image = UIImage(data: data) else { return }
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}

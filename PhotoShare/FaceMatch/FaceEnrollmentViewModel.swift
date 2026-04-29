import Foundation
import _PhotosUI_SwiftUI
import PhotosUI
import UIKit

enum EnrollmentMode {
    case fromProfile
    case manual
}

@MainActor
final class FaceEnrollmentViewModel: ObservableObject {
    let friendId: UUID
    let friendName: String
    let friendHasFaceProfile: Bool

    @Published var mode: EnrollmentMode
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var previewImages: [UIImage] = []
    @Published var isEnrolling = false
    @Published var enrollmentComplete = false
    @Published var error: String?

    private let detector = FaceDetector()
    private let store = FaceEnrollmentStore()
    private let profileManager = FaceProfileManager()

    var isAlreadyEnrolled: Bool { store.hasEnrollment(for: friendId) }
    var canEnroll: Bool { selectedItems.count >= 3 }

    init(friendId: UUID, friendName: String, friendHasFaceProfile: Bool) {
        self.friendId = friendId
        self.friendName = friendName
        self.friendHasFaceProfile = friendHasFaceProfile
        self.mode = friendHasFaceProfile ? .fromProfile : .manual
    }

    func loadPreviews() async {
        var images: [UIImage] = []
        for item in selectedItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        previewImages = images
    }

    func enroll() async {
        switch mode {
        case .fromProfile:
            await enrollFromProfile()
        case .manual:
            await enrollFromSelectedPhotos()
        }
    }

    private func enrollFromProfile() async {
        isEnrolling = true
        defer { isEnrolling = false }

        let images: [UIImage]
        do {
            images = try await profileManager.downloadPhotos(for: friendId)
        } catch {
            self.error = "Could not download \(friendName)'s face profile: \(error.localizedDescription)"
            return
        }

        guard !images.isEmpty else {
            self.error = "\(friendName)'s face profile has no photos. Ask them to update it, or choose your own photos instead."
            return
        }

        await generateAndSaveEmbeddings(from: images)
    }

    private func enrollFromSelectedPhotos() async {
        guard !previewImages.isEmpty else { return }
        isEnrolling = true
        defer { isEnrolling = false }
        await generateAndSaveEmbeddings(from: previewImages)
    }

    private func generateAndSaveEmbeddings(from images: [UIImage]) async {
        var embeddings: [[Float]] = []
        for image in images {
            do {
                let embedding = try await Task.detached(priority: .userInitiated) { [detector, image] in
                    try detector.largestFaceEmbedding(in: image)
                }.value
                if let embedding { embeddings.append(embedding) }
            } catch {
                self.error = "Face detection failed: \(error.localizedDescription)"
                return
            }
        }

        guard embeddings.count >= 2 else {
            error = "Couldn't detect a face in enough photos. Make sure \(friendName)'s face is clearly visible and unobstructed in at least 3 photos."
            return
        }

        do {
            try store.save(embeddings, for: friendId)
            enrollmentComplete = true
        } catch {
            self.error = "Failed to save enrollment: \(error.localizedDescription)"
        }
    }

    func removeEnrollment() {
        store.remove(for: friendId)
    }
}

import Foundation
import _PhotosUI_SwiftUI
import PhotosUI
import UIKit
import Vision

@MainActor
final class FaceEnrollmentViewModel: ObservableObject {
    let friendId: UUID
    let friendName: String

    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var previewImages: [UIImage] = []
    @Published var isEnrolling = false
    @Published var enrollmentComplete = false
    @Published var error: String?

    private let detector = FaceDetector()
    private let store = FaceEnrollmentStore()

    var isAlreadyEnrolled: Bool { store.hasEnrollment(for: friendId) }
    var canEnroll: Bool { selectedItems.count >= 3 }

    init(friendId: UUID, friendName: String) {
        self.friendId = friendId
        self.friendName = friendName
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
        guard !previewImages.isEmpty else { return }
        isEnrolling = true
        defer { isEnrolling = false }

        var observations: [VNFeaturePrintObservation] = []
        for image in previewImages {
            do {
                let obs = try await Task.detached(priority: .userInitiated) { [detector, image] in
                    try detector.largestFaceEmbedding(in: image)
                }.value
                if let obs { observations.append(obs) }
            } catch {
                self.error = "Face detection failed: \(error.localizedDescription)"
                return
            }
        }

        guard observations.count >= 2 else {
            error = "Couldn't detect a face in enough of the selected photos. Make sure \(friendName)'s face is clearly visible and unobstructed in at least 3 photos."
            return
        }

        do {
            try store.save(observations, for: friendId)
            enrollmentComplete = true
        } catch {
            self.error = "Failed to save enrollment: \(error.localizedDescription)"
        }
    }

    func removeEnrollment() {
        store.remove(for: friendId)
    }
}

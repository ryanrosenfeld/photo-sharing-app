#if DEBUG
import PhotosUI
import SwiftUI
import Vision

@MainActor
final class FaceMatchSandboxViewModel: ObservableObject {

    // MARK: - Inputs

    @Published var enrollmentPickerItems: [PhotosPickerItem] = []
    @Published var testPickerItem: [PhotosPickerItem] = []

    // MARK: - Processed images

    @Published var enrollmentImages: [UIImage] = []
    @Published var testImage: UIImage?

    // MARK: - Results

    @Published var enrollmentFaceCounts: [Int] = []
    @Published var testFaceCount: Int = 0
    @Published var distances: [Float] = []
    @Published var threshold: Float = FaceDetector.defaultMatchThreshold
    @Published var isProcessing = false
    @Published var errorMessage: String?

    var minDistance: Float? { distances.first }

    func isMatch(at threshold: Float) -> Bool {
        guard let min = minDistance else { return false }
        return min < threshold
    }

    // MARK: - Private state

    private var enrolledEmbeddings: [VNFeaturePrintObservation] = []
    private var testEmbeddings: [VNFeaturePrintObservation] = []
    private let detector = FaceDetector()

    // MARK: - Actions

    func loadEnrollmentImages() async {
        enrollmentImages = []
        enrolledEmbeddings = []
        enrollmentFaceCounts = []
        distances = []
        errorMessage = nil

        var images: [UIImage] = []
        for item in enrollmentPickerItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        enrollmentImages = images
        await computeEnrollmentEmbeddings()
        await recomputeDistances()
    }

    func loadTestImage() async {
        testImage = nil
        testEmbeddings = []
        distances = []
        errorMessage = nil

        guard let item = testPickerItem.first,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        testImage = image
        await computeTestEmbeddings()
        await recomputeDistances()
    }

    // MARK: - Private helpers

    private func computeEnrollmentEmbeddings() async {
        isProcessing = true
        defer { isProcessing = false }

        var embeddings: [VNFeaturePrintObservation] = []
        var counts: [Int] = []
        for image in enrollmentImages {
            do {
                let embedding = try await Task.detached(priority: .userInitiated) { [detector, image] in
                    try detector.largestFaceEmbedding(in: image)
                }.value
                counts.append(embedding != nil ? 1 : 0)
                if let e = embedding { embeddings.append(e) }
            } catch {
                counts.append(0)
                errorMessage = "Detection error: \(error.localizedDescription)"
            }
        }
        enrolledEmbeddings = embeddings
        enrollmentFaceCounts = counts
    }

    private func computeTestEmbeddings() async {
        guard let image = testImage else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let embeddings = try await Task.detached(priority: .userInitiated) { [detector, image] in
                try detector.allFaceEmbeddings(in: image)
            }.value
            testEmbeddings = embeddings
            testFaceCount = embeddings.count
        } catch {
            testEmbeddings = []
            testFaceCount = 0
            errorMessage = "Detection error: \(error.localizedDescription)"
        }
    }

    private func recomputeDistances() async {
        guard !enrolledEmbeddings.isEmpty, !testEmbeddings.isEmpty else {
            distances = []
            return
        }
        distances = detector.pairwiseDistances(photoFaces: testEmbeddings, enrolled: enrolledEmbeddings)
    }
}
#endif

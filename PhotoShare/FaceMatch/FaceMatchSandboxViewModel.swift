#if DEBUG
import PhotosUI
import SwiftUI

struct FaceDistanceResult: Identifiable {
    let id = UUID()
    let enrollmentImageIndex: Int  // index into enrollmentImages
    let testFaceIndex: Int         // index of face detected in test photo (0 = largest)
    let distance: Float
}

@MainActor
final class FaceMatchSandboxViewModel: ObservableObject {

    // MARK: - Inputs

    @Published var enrollmentPickerItems: [PhotosPickerItem] = []
    @Published var testPickerItem: [PhotosPickerItem] = []

    // MARK: - Processed images

    @Published var enrollmentImages: [UIImage] = []
    @Published var enrollmentFaceCrops: [Int: UIImage] = [:]  // keyed by image index
    @Published var testImage: UIImage?
    @Published var testFaceCrops: [UIImage] = []

    // MARK: - Results

    @Published var enrollmentFaceCounts: [Int] = []
    @Published var testFaceCount: Int = 0
    @Published var distanceResults: [FaceDistanceResult] = []
    @Published var threshold: Float = FaceDetector.defaultMatchThreshold
    @Published var isProcessing = false
    @Published var errorMessage: String?

    var minDistance: Float? { distanceResults.first?.distance }

    func isMatch(at threshold: Float) -> Bool {
        guard let min = minDistance else { return false }
        return min < threshold
    }

    // MARK: - Private state

    // Tuples preserve which enrollment image each embedding came from.
    private var enrolledEmbeddings: [(imageIndex: Int, embedding: [Float])] = []
    private var testEmbeddings: [[Float]] = []
    private let detector = FaceDetector()

    // MARK: - Actions

    func loadEnrollmentImages() async {
        enrollmentImages = []
        enrolledEmbeddings = []
        enrollmentFaceCounts = []
        enrollmentFaceCrops = [:]
        distanceResults = []
        errorMessage = nil

        var images: [UIImage] = []
        for item in enrollmentPickerItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image.preparedForFaceDetection())
            }
        }
        enrollmentImages = images
        await computeEnrollmentEmbeddings()
        recomputeDistances()
    }

    func removeEnrollmentImage(at index: Int) async {
        guard enrollmentImages.indices.contains(index) else { return }
        enrollmentPickerItems.remove(at: index)
        enrollmentImages.remove(at: index)
        if enrollmentFaceCounts.indices.contains(index) {
            enrollmentFaceCounts.remove(at: index)
        }
        await computeEnrollmentEmbeddings()
        recomputeDistances()
    }

    func removeTestImage() {
        testPickerItem = []
        testImage = nil
        testEmbeddings = []
        testFaceCrops = []
        testFaceCount = 0
        distanceResults = []
    }

    func loadTestImage() async {
        testImage = nil
        testEmbeddings = []
        distanceResults = []
        errorMessage = nil

        guard let item = testPickerItem.first,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        testImage = image.preparedForFaceDetection()
        await computeTestEmbeddings()
        recomputeDistances()
    }

    // MARK: - Private helpers

    private func computeEnrollmentEmbeddings() async {
        isProcessing = true
        defer { isProcessing = false }

        var embeddings: [(imageIndex: Int, embedding: [Float])] = []
        var counts: [Int] = []
        var crops: [Int: UIImage] = [:]
        for (imageIndex, image) in enrollmentImages.enumerated() {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [detector, image] in
                    (try detector.largestFaceEmbedding(in: image),
                     try detector.largestFaceCrop(in: image))
                }.value
                let (embedding, crop) = result
                counts.append(embedding != nil ? 1 : 0)
                if let e = embedding { embeddings.append((imageIndex: imageIndex, embedding: e)) }
                if let c = crop { crops[imageIndex] = c }
            } catch {
                counts.append(0)
                errorMessage = "Detection error: \(error.localizedDescription)"
            }
        }
        enrolledEmbeddings = embeddings
        enrollmentFaceCounts = counts
        enrollmentFaceCrops = crops
    }

    private func computeTestEmbeddings() async {
        guard let image = testImage else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try await Task.detached(priority: .userInitiated) { [detector, image] in
                (try detector.allFaceEmbeddings(in: image),
                 try detector.allFaceCrops(in: image))
            }.value
            let (embeddings, crops) = result
            testEmbeddings = embeddings
            testFaceCrops = crops
            testFaceCount = embeddings.count
        } catch {
            testEmbeddings = []
            testFaceCrops = []
            testFaceCount = 0
            errorMessage = "Detection error: \(error.localizedDescription)"
        }
    }

    private func recomputeDistances() {
        guard !enrolledEmbeddings.isEmpty, !testEmbeddings.isEmpty else {
            distanceResults = []
            return
        }
        var results: [FaceDistanceResult] = []
        for (testIdx, testFace) in testEmbeddings.enumerated() {
            for enrolled in enrolledEmbeddings {
                let dist = euclidean(testFace, enrolled.embedding)
                results.append(FaceDistanceResult(
                    enrollmentImageIndex: enrolled.imageIndex,
                    testFaceIndex: testIdx,
                    distance: dist
                ))
            }
        }
        distanceResults = results.sorted { $0.distance < $1.distance }
    }

    private func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }
}
#endif

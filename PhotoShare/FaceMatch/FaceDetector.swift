import UIKit
import Vision

// VNFeaturePrintObservation is an immutable Obj-C class that Apple hasn't
// annotated for Swift 6 concurrency. It's safe to send across actors.
extension VNFeaturePrintObservation: @unchecked Sendable {}

// FaceDetector is a stateless struct — safe to capture into Task.detached.
struct FaceDetector: Sendable {

    // Distance below which two embeddings are considered the same person.
    // Lower = stricter. Tune once real data is available.
    static let defaultMatchThreshold: Float = 0.55

    // MARK: - Public API

    /// Returns the feature-print embedding for the largest detected face in `image`.
    /// Used during enrollment: the friend is assumed to be the primary subject.
    func largestFaceEmbedding(in image: UIImage) throws -> VNFeaturePrintObservation? {
        let faces = try detectFaces(in: image)
        guard let largest = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return nil
        }
        return try featurePrint(croppingTo: largest.boundingBox, in: image)
    }

    /// Returns embeddings for every detected face in `image`.
    /// Used when scanning camera-roll photos to find matching friends.
    func allFaceEmbeddings(in image: UIImage) throws -> [VNFeaturePrintObservation] {
        try detectFaces(in: image).compactMap { face in
            try featurePrint(croppingTo: face.boundingBox, in: image)
        }
    }

    /// Returns all pairwise distances between photoFaces and enrolled embeddings, sorted ascending.
    func pairwiseDistances(
        photoFaces: [VNFeaturePrintObservation],
        enrolled: [VNFeaturePrintObservation]
    ) -> [Float] {
        var distances: [Float] = []
        for face in photoFaces {
            for ref in enrolled {
                var distance: Float = 0
                if (try? face.computeDistance(&distance, to: ref)) != nil {
                    distances.append(distance)
                }
            }
        }
        return distances.sorted()
    }

    /// True if any face in `photoFaces` is within `threshold` of any embedding in `enrolled`.
    func isMatch(
        photoFaces: [VNFeaturePrintObservation],
        enrolled: [VNFeaturePrintObservation],
        threshold: Float = defaultMatchThreshold
    ) -> Bool {
        for face in photoFaces {
            for ref in enrolled {
                var distance: Float = 0
                guard (try? face.computeDistance(&distance, to: ref)) != nil else { continue }
                if distance < threshold { return true }
            }
        }
        return false
    }

    // MARK: - Internals

    private func detectFaces(in image: UIImage) throws -> [VNFaceObservation] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )
        try handler.perform([request])
        return request.results ?? []
    }

    private func featurePrint(croppingTo visionRect: CGRect, in image: UIImage) throws -> VNFeaturePrintObservation? {
        guard let crop = image.croppingToVisionRect(visionRect),
              let cropCG = crop.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cropCG, options: [:])
        try handler.perform([request])
        return request.results?.first
    }
}

// MARK: - UIImage Vision crop

private extension UIImage {
    /// Crops to a Vision-normalized bounding box (origin at bottom-left).
    func croppingToVisionRect(_ visionRect: CGRect) -> UIImage? {
        let w = size.width * scale
        let h = size.height * scale
        let rect = CGRect(
            x: visionRect.minX * w,
            y: (1 - visionRect.maxY) * h,
            width: visionRect.width * w,
            height: visionRect.height * h
        )
        guard let cropped = cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}

// MARK: - Helpers

private extension CGRect {
    var area: CGFloat { width * height }
}

private extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up:            self = .up
        case .down:          self = .down
        case .left:          self = .left
        case .right:         self = .right
        case .upMirrored:    self = .upMirrored
        case .downMirrored:  self = .downMirrored
        case .leftMirrored:  self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}

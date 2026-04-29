import CoreML
import UIKit
import Vision

enum FaceDetectorError: Error, LocalizedError {
    case modelNotFound

    var errorDescription: String? {
        "MobileFaceNet.mlpackage is not in the app bundle. Run scripts/convert_mobilefacenet.py then add the output to the Xcode target."
    }
}

// FaceDetector is a stateless struct — safe to capture into Task.detached.
struct FaceDetector: Sendable {

    // Euclidean distance threshold for MobileFaceNet embeddings.
    // Same person across varied lighting/pose: ~0.3–0.4. Different people: >0.6.
    static let defaultMatchThreshold: Float = 0.35

    // MARK: - Public API

    /// Returns the 128-D MobileFaceNet embedding for the largest detected face in `image`.
    /// Used during enrollment: the friend is assumed to be the primary subject.
    func largestFaceEmbedding(in image: UIImage) throws -> [Float]? {
        let faces = try detectFaces(in: image)
        guard let largest = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return nil
        }
        return try embedding(croppingTo: largest.boundingBox, in: image)
    }

    /// Returns 128-D embeddings for every detected face in `image`.
    /// Used when scanning camera-roll photos to find matching friends.
    func allFaceEmbeddings(in image: UIImage) throws -> [[Float]] {
        try detectFaces(in: image).compactMap { face in
            try embedding(croppingTo: face.boundingBox, in: image)
        }
    }

    /// Returns all pairwise Euclidean distances between photoFaces and enrolled embeddings, sorted ascending.
    func pairwiseDistances(
        photoFaces: [[Float]],
        enrolled: [[Float]]
    ) -> [Float] {
        var distances: [Float] = []
        for face in photoFaces {
            for ref in enrolled {
                distances.append(euclidean(face, ref))
            }
        }
        return distances.sorted()
    }

    /// True if any face in `photoFaces` is within `threshold` of any embedding in `enrolled`.
    func isMatch(
        photoFaces: [[Float]],
        enrolled: [[Float]],
        threshold: Float = defaultMatchThreshold
    ) -> Bool {
        pairwiseDistances(photoFaces: photoFaces, enrolled: enrolled).first.map { $0 < threshold } ?? false
    }

    // MARK: - CoreML model

    // Loaded once at first use. Returns nil (and surfaces FaceDetectorError.modelNotFound) if the
    // mlpackage hasn't been added to the Xcode target yet.
    private static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc") else {
            return nil
        }
        return try? MLModel(contentsOf: url)
    }()

    // MARK: - Internals

    private func embedding(croppingTo visionRect: CGRect, in image: UIImage) throws -> [Float]? {
        guard let model = Self.model else { throw FaceDetectorError.modelNotFound }
        guard let crop = image.croppingToVisionRect(visionRect),
              let resized = crop.resized(to: CGSize(width: 112, height: 112)),
              let pixelBuffer = resized.pixelBuffer(width: 112, height: 112) else { return nil }

        let input = try MLDictionaryFeatureProvider(dictionary: ["input_1": pixelBuffer])
        let output = try model.prediction(from: input)

        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return (0..<array.count).map { Float(truncating: array[$0]) }
    }

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

    private func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }
}

// MARK: - UIImage helpers

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

    func resized(to size: CGSize) -> UIImage? {
        UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Returns a 32BGRA CVPixelBuffer at the requested dimensions.
    /// CoreML handles the BGRA→BGR channel reorder and [-1,1] normalization (baked in at model conversion time).
    func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard let cgImage else { return nil }
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
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

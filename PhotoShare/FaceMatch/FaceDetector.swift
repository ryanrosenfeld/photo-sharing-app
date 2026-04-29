import CoreML
import UIKit
import Vision

extension MLModel: @unchecked Sendable {}

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

    // Fraction of the bounding box size added as padding on each side.
    // MobileFaceNet was trained with some context around the face, not a tight crop.
    private static let cropPadding: CGFloat = 0.25

    // MARK: - Public API

    /// Returns the 128-D MobileFaceNet embedding for the largest detected face in `image`.
    /// Used during enrollment: the friend is assumed to be the primary subject.
    func largestFaceEmbedding(in image: UIImage) throws -> [Float]? {
        let prepared = image.preparedForFaceDetection()
        let faces = try detectFaces(in: prepared)
        guard let largest = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return nil
        }
        return try embedding(croppingTo: largest.boundingBox.padded(by: Self.cropPadding), in: prepared)
    }

    /// Returns 128-D embeddings for every detected face in `image`.
    /// Used when scanning camera-roll photos to find matching friends.
    func allFaceEmbeddings(in image: UIImage) throws -> [[Float]] {
        let prepared = image.preparedForFaceDetection()
        return try detectFaces(in: prepared).compactMap { face in
            try embedding(croppingTo: face.boundingBox.padded(by: Self.cropPadding), in: prepared)
        }
    }

    /// Returns the cropped face image used for the largest-face embedding (mirrors enrollment logic).
    func largestFaceCrop(in image: UIImage) throws -> UIImage? {
        let prepared = image.preparedForFaceDetection()
        let faces = try detectFaces(in: prepared)
        guard let largest = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else { return nil }
        return prepared.croppingToVisionRect(largest.boundingBox.padded(by: Self.cropPadding))
    }

    /// Returns cropped face images for every detected face in `image` (mirrors allFaceEmbeddings order).
    func allFaceCrops(in image: UIImage) throws -> [UIImage] {
        let prepared = image.preparedForFaceDetection()
        return try detectFaces(in: prepared).compactMap {
            prepared.croppingToVisionRect($0.boundingBox.padded(by: Self.cropPadding))
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

    // Image must already have orientation normalized to .up before calling this.
    private func detectFaces(in image: UIImage) throws -> [VNFaceObservation] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    private func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }
}

// MARK: - UIImage helpers

extension UIImage {
    /// Normalizes orientation to .up and downsamples to at most `maxDimension` on the longest side.
    /// Called before every Vision + CoreML pipeline to avoid OOM on full-resolution camera photos.
    func preparedForFaceDetection(maxDimension: CGFloat = 1024) -> UIImage {
        let longest = max(size.width, size.height)
        let needsResize = longest > maxDimension
        let targetSize: CGSize
        if needsResize {
            let scale = maxDimension / longest
            targetSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        } else {
            targetSize = size
        }
        guard imageOrientation != .up || needsResize else { return self }
        return UIGraphicsImageRenderer(size: targetSize).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Crops to a Vision-normalized bounding box (origin at bottom-left, image must be .up orientation).
    /// Uses cgImage pixel dimensions directly since UIGraphicsImageRenderer produces images at display
    /// scale (3x on iPhone) — image.size is in points but cgImage is in pixels.
    func croppingToVisionRect(_ visionRect: CGRect) -> UIImage? {
        guard let cgImage else { return nil }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let rect = CGRect(
            x: visionRect.minX * w,
            y: (1 - visionRect.maxY) * h,
            width: visionRect.width * w,
            height: visionRect.height * h
        )
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
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

    /// Expands the Vision bounding box by `fraction` of its size on each side, clamped to [0,1].
    func padded(by fraction: CGFloat) -> CGRect {
        let dx = width * fraction
        let dy = height * fraction
        return CGRect(
            x: max(0, minX - dx),
            y: max(0, minY - dy),
            width: min(1 - max(0, minX - dx), width + dx * 2),
            height: min(1 - max(0, minY - dy), height + dy * 2)
        )
    }
}

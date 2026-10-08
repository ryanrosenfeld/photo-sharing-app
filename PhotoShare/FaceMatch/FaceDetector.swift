import CoreML
import CoreGraphics
import ImageIO
import Vision
#if canImport(UIKit)
import UIKit
#endif

extension MLModel: @unchecked Sendable {}

enum FaceDetectorError: Error, LocalizedError {
    case modelNotFound

    var errorDescription: String? {
        "MobileFaceNet.mlpackage is not in the app bundle. Run scripts/convert_mobilefacenet.py then add the output to the Xcode target."
    }
}

/// Detect -> align -> embed. The core works on CGImage so the same code runs in the app, in the XCTest
/// harness (Simulator) and in the macOS evaluation tool (scripts/verify/facematch-mac.sh), where Vision
/// landmarks are real (the Simulator's landmark detector returns garbage; see `FaceAligner.plausible`).
// FaceDetector is a stateless struct — safe to capture into Task.detached.
struct FaceDetector: Sendable {

    // Cosine-distance threshold (1 - cos similarity, range 0...2) for MobileFaceNet embeddings (buffalo_sc / w600k_mbf).
    // The model outputs unnormalized 512-D vectors whose length varies with image quality, so raw Euclidean distance
    // mixes quality into identity; cosine ignores length. 0.55 sits between real-photo same-person distances
    // (LFW: p95 0.545, max 0.616) and the closest different-person pair (0.687) -- see docs/face-matching/README.md.
    #if FACEMATCH_ABLATE_EUCLID
    static let defaultMatchThreshold: Float = 15   // evaluation-only: the pre-change raw Euclidean threshold
    #else
    static let defaultMatchThreshold: Float = 0.55
    #endif

    /// Longest image side handed to Vision. Bigger frames are downsampled (OOM on 12 MP camera photos).
    static let maxDimension: CGFloat = 1024

    // Fallback crop (only when landmarks are missing/implausible): fraction of the box added on each side.
    fileprivate static let cropPadding: CGFloat = 0.25

    // MARK: - CGImage API (image must already be orientation-normalized and downsampled: see `prepared`)

    /// Embedding of the largest detected face. Used during enrollment: the friend is the primary subject.
    func largestFaceEmbedding(in image: CGImage) throws -> [Float]? {
        guard let largest = try detectFaces(in: image).max(by: { $0.boundingBox.area < $1.boundingBox.area }) else { return nil }
        return try embedding(for: largest, in: image)
    }

    /// Embeddings for every detected face. Used when scanning camera-roll photos to find matching friends.
    func allFaceEmbeddings(in image: CGImage) throws -> [[Float]] {
        try detectFaces(in: image).compactMap { try embedding(for: $0, in: image) }
    }

    /// The 112x112 model input for the largest face (what the sandbox shows). Debug/test aid.
    func largestFaceCrop(in image: CGImage) throws -> CGImage? {
        guard let largest = try detectFaces(in: image).max(by: { $0.boundingBox.area < $1.boundingBox.area }) else { return nil }
        return FaceAligner.crop112(for: largest, in: image)
    }

    /// 112x112 model inputs for every face, in `allFaceEmbeddings` order. Debug/test aid.
    func allFaceCrops(in image: CGImage) throws -> [CGImage] {
        try detectFaces(in: image).compactMap { FaceAligner.crop112(for: $0, in: image) }
    }

    /// Detections for debugging: Vision box (normalized, bottom-left origin) and whether alignment was used.
    func faceDiagnostics(in image: CGImage) throws -> [(box: CGRect, aligned: Bool, landmarks: FaceAligner.Landmarks?)] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return try detectFaces(in: image).map { face in
            let l = FaceAligner.landmarks(of: face, imageWidth: w, imageHeight: h)
            return (face.boundingBox, l.map { FaceAligner.plausible($0, face: face, imageWidth: w) } ?? false, l)
        }
    }

    // MARK: - Distances

    /// All pairwise cosine distances between photoFaces and enrolled embeddings, sorted ascending.
    func pairwiseDistances(photoFaces: [[Float]], enrolled: [[Float]]) -> [Float] {
        var distances: [Float] = []
        for face in photoFaces {
            for ref in enrolled {
                distances.append(cosineDistance(face, ref))
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

    // MARK: - Loading

    /// Decodes `url` with EXIF orientation applied, downsampled to at most `maxDimension` px (never decodes the full frame).
    static func prepared(url: URL, maxDimension: CGFloat = FaceDetector.maxDimension) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: - CoreML model

    private static let model: MLModel? = {
        // FACEMATCH_MODEL_PATH lets the macOS evaluation tool point at a compiled .mlmodelc outside an app bundle.
        let url = ProcessInfo.processInfo.environment["FACEMATCH_MODEL_PATH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc")
        guard let url else { return nil }
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // Default compute units yield an all-zero embedding on the Simulator; CPU-only is correct.
        config.computeUnits = .cpuOnly
        #endif
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    // MARK: - Internals

    private func embedding(for face: VNFaceObservation, in image: CGImage) throws -> [Float]? {
        guard let model = Self.model else { throw FaceDetectorError.modelNotFound }
        guard let crop = FaceAligner.crop112(for: face, in: image),
              let pixelBuffer = crop.pixelBuffer() else { return nil }

        let input = try MLDictionaryFeatureProvider(dictionary: ["input_1": pixelBuffer])
        let output = try model.prediction(from: input)

        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return (0..<array.count).map { Float(truncating: array[$0]) }
    }

    private func detectFaces(in image: CGImage) throws -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        #if targetEnvironment(simulator)
        // The Simulator has no GPU/ANE for Vision: without this it throws "Could not create inference context".
        request.usesCPUOnly = true
        #endif
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// 1 - cos(a, b); 0 = same direction, ~1 = unrelated, 2 = opposite.
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        #if FACEMATCH_ABLATE_EUCLID
        return zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
        #else
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for (x, y) in zip(a, b) { dot += x * y; na += x * x; nb += y * y }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? 1 - dot / denom : 2
        #endif
    }
}

// MARK: - Alignment

/// ArcFace-style alignment: warp the face so eyes, nose and mouth land on the canonical 112x112 template the
/// model was trained on. A padded bounding box (the old approach) leaves scale, roll and background context to chance.
enum FaceAligner {

    /// ArcFace 5-point template in 112x112 (image-left eye, image-right eye, nose, mouth left, mouth right).
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Landmarks in image pixels (origin top-left): eyes ordered image-left first.
    struct Landmarks {
        var leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint, mouthLeft: CGPoint, mouthRight: CGPoint
        var points: [CGPoint] { [leftEye, rightEye, nose, mouthLeft, mouthRight] }
    }

    static func landmarks(of face: VNFaceObservation, imageWidth w: CGFloat, imageHeight h: CGFloat) -> Landmarks? {
        guard let lm = face.landmarks,
              let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints,
              let nose = lm.nose?.normalizedPoints, let lips = lm.outerLips?.normalizedPoints,
              !le.isEmpty, !re.isEmpty, !nose.isEmpty, lips.count >= 4 else { return nil }
        let bb = face.boundingBox
        // Vision landmark points are normalized to the face box, origin bottom-left.
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (bb.minX + p.x * bb.width) * w, y: (1 - (bb.minY + p.y * bb.height)) * h)
        }
        func mean(_ ps: [CGPoint]) -> CGPoint {
            let m = ps.map(px)
            return CGPoint(x: m.map(\.x).reduce(0, +) / CGFloat(m.count), y: m.map(\.y).reduce(0, +) / CGFloat(m.count))
        }
        let eyes = [mean(le), mean(re)].sorted { $0.x < $1.x }
        let lipPx = lips.map(px)
        guard let ml = lipPx.min(by: { $0.x < $1.x }), let mr = lipPx.max(by: { $0.x < $1.x }) else { return nil }
        return Landmarks(leftEye: eyes[0], rightEye: eyes[1], nose: mean(nose), mouthLeft: ml, mouthRight: mr)
    }

    /// Sanity check: eyes a plausible distance apart relative to the box, mouth well below the eyes, limited roll.
    /// Rejects the Simulator's collapsed landmarks so we fall back to the box crop instead of aligning garbage.
    static func plausible(_ l: Landmarks, face: VNFaceObservation, imageWidth w: CGFloat) -> Bool {
        let boxW = face.boundingBox.width * w
        guard boxW > 8 else { return false }
        let eyeDx = l.rightEye.x - l.leftEye.x, eyeDy = l.rightEye.y - l.leftEye.y
        let eyeDist = (eyeDx * eyeDx + eyeDy * eyeDy).squareRoot()
        guard eyeDist > 1 else { return false }
        let mouth = CGPoint(x: (l.mouthLeft.x + l.mouthRight.x) / 2, y: (l.mouthLeft.y + l.mouthRight.y) / 2)
        let eyeMid = CGPoint(x: (l.leftEye.x + l.rightEye.x) / 2, y: (l.leftEye.y + l.rightEye.y) / 2)
        // distance of the mouth from the eye midpoint along the face's "down" axis (perpendicular to the eye line)
        let drop = ((mouth.x - eyeMid.x) * -eyeDy + (mouth.y - eyeMid.y) * eyeDx) / eyeDist
        let roll = abs(atan2(eyeDy, eyeDx))
        return eyeDist / boxW > 0.25 && eyeDist / boxW < 0.85 && drop / eyeDist > 0.7 && roll < 1.2
    }

    /// The 112x112 crop fed to the model. Aligned when landmarks are usable, else the padded box crop.
    static func crop112(for face: VNFaceObservation, in image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        #if FACEMATCH_ABLATE_BOX
        // Evaluation-only build flag: reproduce the pre-alignment pipeline (padded box crop) for before/after numbers.
        return boxCrop112(for: face, in: image)
        #endif
        if let l = landmarks(of: face, imageWidth: w, imageHeight: h), plausible(l, face: face, imageWidth: w),
           let t = similarity(from: l.points, to: template),
           let out = warp(image, by: t) { return out }
        return boxCrop112(for: face, in: image)
    }

    static func boxCrop112(for face: VNFaceObservation, in image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let r = face.boundingBox.padded(by: FaceDetector.cropPadding)
        let rect = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        guard let cropped = image.cropping(to: rect) else { return nil }
        return render(size: 112) { ctx in
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        }
    }

    /// Draws `image` through `t` (image px, top-left origin -> 112x112 template space, top-left origin).
    static func warp(_ image: CGImage, by t: CGAffineTransform) -> CGImage? {
        let h = CGFloat(image.height)
        return render(size: 112) { ctx in
            ctx.translateBy(x: 0, y: 112); ctx.scaleBy(x: 1, y: -1)    // top-left origin for the destination
            ctx.concatenate(t)                                          // image px -> template space
            ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)       // CG draws images bottom-left
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: h))
        }
    }

    private static func render(size: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))   // area outside the source frame
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        body(ctx)
        return ctx.makeImage()
    }

    /// Least-squares similarity transform (rotation + uniform scale + translation, no reflection) src -> dst.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        let n = CGFloat(src.count)
        let sc = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let dc = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var dot: CGFloat = 0, cross: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - sc.x, sy = s.y - sc.y, dx = d.x - dc.x, dy = d.y - dc.y
            dot += sx * dx + sy * dy
            cross += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        guard den > 1e-6 else { return nil }
        let a = dot / den, b = cross / den
        guard a.isFinite, b.isFinite else { return nil }
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: dc.x - (a * sc.x - b * sc.y), ty: dc.y - (b * sc.x + a * sc.y))
    }
}

// MARK: - CGImage / CGRect helpers

extension CGImage {
    /// 32BGRA CVPixelBuffer at the image's own size (112x112 crops).
    /// CoreML handles the BGRA->BGR channel reorder and [-1,1] normalization (baked in at model conversion time).
    func pixelBuffer() -> CVPixelBuffer? {
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

        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

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

// MARK: - UIKit conveniences (app + XCTest only)

#if canImport(UIKit)
extension FaceDetector {
    /// Embedding of the largest face in `image` (enrollment).
    func largestFaceEmbedding(in image: UIImage) throws -> [Float]? {
        guard let cg = image.preparedCGImage() else { return nil }
        return try largestFaceEmbedding(in: cg)
    }

    /// Embeddings for every face in `image` (camera-roll scan).
    func allFaceEmbeddings(in image: UIImage) throws -> [[Float]] {
        guard let cg = image.preparedCGImage() else { return [] }
        return try allFaceEmbeddings(in: cg)
    }

    /// The 112x112 crop the model sees for the largest face (what the sandbox shows).
    func largestFaceCrop(in image: UIImage) throws -> UIImage? {
        guard let cg = image.preparedCGImage(), let crop = try largestFaceCrop(in: cg) else { return nil }
        return UIImage(cgImage: crop, scale: 1, orientation: .up)
    }

    /// 112x112 model inputs for every face, in `allFaceEmbeddings` order.
    func allFaceCrops(in image: UIImage) throws -> [UIImage] {
        guard let cg = image.preparedCGImage() else { return [] }
        return try allFaceCrops(in: cg).map { UIImage(cgImage: $0, scale: 1, orientation: .up) }
    }
}

extension UIImage {
    /// Orientation-normalized (.up) pixels, downsampled to at most `maxDimension` px on the longest side.
    /// Rendered at scale 1 so point size == pixel size (display-scale rendering caused a past crop bug).
    func preparedCGImage(maxDimension: CGFloat = FaceDetector.maxDimension) -> CGImage? {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(pixelSize.width, pixelSize.height)
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        if imageOrientation == .up, factor == 1, let cg = cgImage { return cg }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }

    /// `preparedCGImage` as a UIImage (for display and for callers that keep working with UIImage).
    func preparedForFaceDetection(maxDimension: CGFloat = FaceDetector.maxDimension) -> UIImage {
        guard let cg = preparedCGImage(maxDimension: maxDimension) else { return self }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}
#endif

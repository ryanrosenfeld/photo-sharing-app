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

/// A face embedding plus how it was made. Faces whose landmarks could not be aligned fall back to a padded box
/// crop, which is far less reliable (see docs/face-matching), so comparisons involving them are penalised.
struct FaceEmbedding: Codable, Sendable, Equatable {
    var vector: [Float]
    var aligned: Bool
}

/// A detected face in the coordinate space of the image it was found in (pixels, origin top-left).
struct DetectedFace: Sendable {
    let box: CGRect
    /// Raw Vision landmarks (may be implausible, e.g. on the Simulator); see `alignedLandmarks`.
    let landmarks: FaceAligner.Landmarks?

    /// Landmarks good enough to align on, else nil (-> box-crop fallback).
    var alignedLandmarks: FaceAligner.Landmarks? {
        landmarks.flatMap { FaceAligner.plausible($0, faceWidth: box.width) ? $0 : nil }
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

    /// Added to the distance when either embedding came from the box-crop fallback, i.e. unaligned faces must be
    /// 0.2 closer to match. On LFW, box-crop impostors reach 0.34 while aligned ones stay above 0.65.
    static let unalignedPenalty: Float = 0.2

    /// Longest image side kept for detection. Vision's detector misses faces below ~5% of the frame, so large
    /// photos are scanned as an image pyramid of 1024px tiles (see `detectFaces`) instead of being squeezed to 1024.
    static let maxDimension: CGFloat = 4096

    private static let tileSize: CGFloat = 1024
    private static let tileStride: CGFloat = 768          // 25% overlap so a face is whole in at least one tile
    private static let minFacePixels: CGFloat = 32        // smaller heads carry too little detail to embed
    private static let landmarkRegionScale: CGFloat = 1.8 // landmarks are re-detected on a crop this many times the box

    // Fallback crop (only when landmarks are missing/implausible): fraction of the box added on each side.
    fileprivate static let cropPadding: CGFloat = 0.25

    // MARK: - CGImage API (image must already be orientation-normalized: see `prepared` / `preparedCGImage`)

    /// Embedding of the largest detected face. Used during enrollment: the friend is the primary subject.
    func largestFaceEmbedding(in image: CGImage) throws -> FaceEmbedding? {
        guard let largest = try detectFaces(in: image).max(by: { $0.box.area < $1.box.area }) else { return nil }
        return try embedding(for: largest, in: image)
    }

    /// Embeddings for every detected face. Used when scanning camera-roll photos to find matching friends.
    func allFaceEmbeddings(in image: CGImage) throws -> [FaceEmbedding] {
        try detectFaces(in: image).compactMap { try embedding(for: $0, in: image) }
    }

    /// The 112x112 model input for the largest face (what the sandbox shows). Debug/test aid.
    func largestFaceCrop(in image: CGImage) throws -> CGImage? {
        guard let largest = try detectFaces(in: image).max(by: { $0.box.area < $1.box.area }) else { return nil }
        return FaceAligner.crop112(for: largest, in: image)
    }

    /// 112x112 model inputs for every face, in `allFaceEmbeddings` order. Debug/test aid.
    func allFaceCrops(in image: CGImage) throws -> [CGImage] {
        try detectFaces(in: image).compactMap { FaceAligner.crop112(for: $0, in: image) }
    }

    /// Detected faces (boxes + landmarks in image pixels). Debug/test aid.
    func faceDiagnostics(in image: CGImage) throws -> [DetectedFace] {
        try detectFaces(in: image)
    }

    // MARK: - Distances

    /// All pairwise cosine distances between photoFaces and enrolled embeddings, sorted ascending.
    func pairwiseDistances(photoFaces: [FaceEmbedding], enrolled: [FaceEmbedding]) -> [Float] {
        var distances: [Float] = []
        for face in photoFaces {
            for ref in enrolled {
                let penalty = face.aligned && ref.aligned ? 0 : Self.unalignedPenalty
                distances.append(cosineDistance(face.vector, ref.vector) + penalty)
            }
        }
        return distances.sorted()
    }

    /// True if any face in `photoFaces` is within `threshold` of any embedding in `enrolled`.
    func isMatch(
        photoFaces: [FaceEmbedding],
        enrolled: [FaceEmbedding],
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

    // MARK: - Embedding

    private func embedding(for face: DetectedFace, in image: CGImage) throws -> FaceEmbedding? {
        guard let model = Self.model else { throw FaceDetectorError.modelNotFound }
        guard let crop = FaceAligner.crop112(for: face, in: image), let v = try embed(crop, with: model) else { return nil }
        #if FACEMATCH_ABLATE_BOX
        return FaceEmbedding(vector: v, aligned: true)   // evaluation-only: no penalty, matches the pre-change pipeline
        #else
        return FaceEmbedding(vector: v, aligned: face.alignedLandmarks != nil)
        #endif
    }

    private func embed(_ crop: CGImage, with model: MLModel) throws -> [Float]? {
        guard let pixelBuffer = crop.pixelBuffer() else { return nil }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_1": pixelBuffer])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return (0..<array.count).map { Float(truncating: array[$0]) }
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

    // MARK: - Detection

    /// Finds faces at every size: scans the whole image plus, for big images, an image pyramid of 1024px tiles
    /// (Vision's detector returns nothing for faces under ~5% of the frame, which is what small faces in
    /// wide shots are), merges duplicates, then re-detects landmarks on a crop of each face.
    private func detectFaces(in image: CGImage) throws -> [DetectedFace] {
        let w = CGFloat(image.width), h = CGFloat(image.height), longest = max(w, h)
        var candidates: [(rect: CGRect, confidence: Float)] = []

        // pyramid levels (longest side in px): 1024 sees big faces, 2048 and native see small ones
        var targets: Set<CGFloat> = [min(longest, Self.tileSize)]
        if longest > 1536 { targets.insert(min(longest, 2048)) }
        if longest > 2560 { targets.insert(min(longest, 4096)) }
        for target in targets.sorted() {
            let scale = target / longest
            guard let level = target < longest ? image.resized(to: CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())) : image else { continue }
            let lw = CGFloat(level.width), lh = CGFloat(level.height)
            for tile in Self.tiles(width: lw, height: lh) {
                guard let crop = level.cropping(to: tile) else { continue }
                for obs in try Self.detectRectangles(in: crop) {
                    var r = obs.boundingBox.pixelRect(width: tile.width, height: tile.height)
                    // drop faces cut off by an interior tile border (a neighbouring tile has them whole)
                    let margin = tile.width * 0.015
                    if (r.minX < margin && tile.minX > 0) || (r.maxX > tile.width - margin && tile.maxX < lw)
                        || (r.minY < margin && tile.minY > 0) || (r.maxY > tile.height - margin && tile.maxY < lh) { continue }
                    r = r.offsetBy(dx: tile.minX, dy: tile.minY)
                    let back = 1 / scale
                    r = CGRect(x: r.minX * back, y: r.minY * back, width: r.width * back, height: r.height * back)
                    if r.width >= Self.minFacePixels { candidates.append((r, obs.confidence)) }
                }
            }
        }
        return try Self.suppressDuplicates(candidates).compactMap { try refine(box: $0, in: image) }
    }

    /// Overlapping tiles of `tileSize` covering the image (one tile if the image fits).
    private static func tiles(width: CGFloat, height: CGFloat) -> [CGRect] {
        func starts(_ length: CGFloat) -> [CGFloat] {
            guard length > tileSize else { return [0] }
            var s: [CGFloat] = []
            var x: CGFloat = 0
            while x + tileSize < length { s.append(x); x += tileStride }
            s.append(length - tileSize)
            return s
        }
        let tw = min(width, tileSize), th = min(height, tileSize)
        return starts(height).flatMap { y in starts(width).map { x in CGRect(x: x, y: y, width: tw, height: th) } }
    }

    private static func detectRectangles(in image: CGImage) throws -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        #if targetEnvironment(simulator)
        // The Simulator has no GPU/ANE for Vision: without this it throws "Could not create inference context".
        request.usesCPUOnly = true
        #endif
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    /// Non-maximum suppression: keep the most confident (then largest) box of each overlapping group.
    private static func suppressDuplicates(_ boxes: [(rect: CGRect, confidence: Float)]) -> [CGRect] {
        var kept: [CGRect] = []
        for b in boxes.sorted(by: { ($0.confidence, $0.rect.area) > ($1.confidence, $1.rect.area) }) {
            let dup = kept.contains { k in
                let inter = k.intersection(b.rect)
                guard !inter.isNull else { return false }
                let i = inter.area
                return i / (k.area + b.rect.area - i) > 0.35 || i / min(k.area, b.rect.area) > 0.7
            }
            if !dup { kept.append(b.rect) }
        }
        return kept
    }

    /// Landmarks are detected again on a crop around the face, upscaled to a comfortable size: far more accurate for
    /// small faces than the landmarks of a whole-frame pass, and bounded in cost for large ones.
    private func refine(box: CGRect, in image: CGImage) throws -> DetectedFace? {
        let side = max(box.width, box.height) * Self.landmarkRegionScale
        let center = CGPoint(x: box.midX, y: box.midY)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let region = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).intersection(bounds).integral
        guard !region.isNull, let regionImage = image.cropping(to: region) else { return DetectedFace(box: box, landmarks: nil) }
        // work on a 320...640px crop: upscale small faces, downscale large ones
        let k: CGFloat = region.width < 320 ? 320 / region.width : (region.width > 640 ? 640 / region.width : 1)
        let scaled = k == 1 ? regionImage : (regionImage.resized(to: CGSize(width: (region.width * k).rounded(), height: (region.height * k).rounded())) ?? regionImage)
        let sw = CGFloat(scaled.width), sh = CGFloat(scaled.height)

        let request = VNDetectFaceLandmarksRequest()
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        try VNImageRequestHandler(cgImage: scaled, options: [:]).perform([request])

        // the observation that best overlaps where we expect the face (box in scaled-crop pixels)
        let expected = CGRect(x: (box.minX - region.minX) * k, y: (box.minY - region.minY) * k, width: box.width * k, height: box.height * k)
        let best = (request.results ?? []).max { a, b in
            a.boundingBox.pixelRect(width: sw, height: sh).iou(expected) < b.boundingBox.pixelRect(width: sw, height: sh).iou(expected)
        }
        guard let obs = best, obs.boundingBox.pixelRect(width: sw, height: sh).iou(expected) > 0.3,
              let l = FaceAligner.landmarks(of: obs, imageWidth: sw, imageHeight: sh) else {
            return DetectedFace(box: box, landmarks: nil)
        }
        func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: region.minX + p.x / k, y: region.minY + p.y / k) }
        let mapped = FaceAligner.Landmarks(
            leftEye: toImage(l.leftEye), rightEye: toImage(l.rightEye), nose: toImage(l.nose),
            mouthLeft: toImage(l.mouthLeft), mouthRight: toImage(l.mouthRight))
        // box from the landmark pass is tighter/more consistent than the detector's; keep the detector box for ordering
        return DetectedFace(box: box, landmarks: mapped)
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
    struct Landmarks: Sendable {
        var leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint, mouthLeft: CGPoint, mouthRight: CGPoint
        var points: [CGPoint] { [leftEye, rightEye, nose, mouthLeft, mouthRight] }
    }

    /// Landmarks of a Vision observation in pixels of the image it was detected in.
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

    /// Sanity check: eyes a plausible distance apart relative to the face, mouth well below the eyes, limited roll.
    /// Rejects the Simulator's collapsed landmarks so we fall back to the box crop instead of aligning garbage.
    static func plausible(_ l: Landmarks, faceWidth boxW: CGFloat) -> Bool {
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
    static func crop112(for face: DetectedFace, in image: CGImage) -> CGImage? {
        #if FACEMATCH_ABLATE_BOX
        // Evaluation-only build flag: reproduce the pre-alignment pipeline (padded box crop) for before/after numbers.
        return boxCrop112(for: face, in: image)
        #else
        if let l = face.alignedLandmarks, let t = similarity(from: l.points, to: template),
           let out = warp(image, by: t) { return out }
        return boxCrop112(for: face, in: image)
        #endif
    }

    static func boxCrop112(for face: DetectedFace, in image: CGImage) -> CGImage? {
        let b = face.box
        let pad = FaceDetector.cropPadding
        let rect = CGRect(x: b.minX - b.width * pad, y: b.minY - b.height * pad, width: b.width * (1 + 2 * pad), height: b.height * (1 + 2 * pad))
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))).integral
        guard !rect.isNull, let cropped = image.cropping(to: rect) else { return nil }
        return render(size: 112) { ctx in
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        }
    }

    /// Draws `image` through `t` (image px, top-left origin -> 112x112 template space, top-left origin).
    /// Only the source region the 112x112 window covers is touched, and big sources are halved first so
    /// a 1000px face is area-averaged down instead of aliased.
    static func warp(_ image: CGImage, by t: CGAffineTransform) -> CGImage? {
        guard abs(t.a * t.d - t.b * t.c) > 1e-9 else { return nil }
        let inv = t.inverted()
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 112, y: 0), CGPoint(x: 0, y: 112), CGPoint(x: 112, y: 112)].map { $0.applying(inv) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let region = CGRect(x: xs.min()! - 2, y: ys.min()! - 2, width: xs.max()! - xs.min()! + 4, height: ys.max()! - ys.min()! + 4)
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))).integral
        guard !region.isNull, region.width >= 1, region.height >= 1, var src = image.cropping(to: region) else { return render(size: 112) { _ in } }
        // image px -> region px -> (optional halvings) -> template
        var tt = CGAffineTransform(translationX: region.minX, y: region.minY).concatenating(t)
        var scale = (tt.a * tt.a + tt.b * tt.b).squareRoot()
        while scale < 0.5, src.width >= 8, src.height >= 8,
              let half = src.resized(to: CGSize(width: (src.width + 1) / 2, height: (src.height + 1) / 2)) {
            src = half
            tt = CGAffineTransform(scaleX: 2, y: 2).concatenating(tt)   // region-px of the half-size image are 2x as large
            scale *= 2
        }
        let h = CGFloat(src.height)
        return render(size: 112) { ctx in
            ctx.translateBy(x: 0, y: 112); ctx.scaleBy(x: 1, y: -1)    // top-left origin for the destination
            ctx.concatenate(tt)                                         // source px -> template space
            ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)       // CG draws images bottom-left
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: CGFloat(src.width), height: h))
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
    /// High-quality resample to `size` (top-left origin, opaque).
    func resized(to size: CGSize) -> CGImage? {
        guard size.width >= 1, size.height >= 1, let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

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

    /// Vision normalized rect (origin bottom-left) -> pixel rect (origin top-left).
    func pixelRect(width w: CGFloat, height h: CGFloat) -> CGRect {
        CGRect(x: minX * w, y: (1 - maxY) * h, width: width * w, height: height * h)
    }

    func iou(_ other: CGRect) -> CGFloat {
        let inter = intersection(other)
        guard !inter.isNull else { return 0 }
        return inter.area / (area + other.area - inter.area)
    }
}

// MARK: - UIKit conveniences (app + XCTest only)

#if canImport(UIKit)
extension FaceDetector {
    /// Embedding of the largest face in `image` (enrollment).
    func largestFaceEmbedding(in image: UIImage) throws -> FaceEmbedding? {
        guard let cg = image.preparedCGImage() else { return nil }
        return try largestFaceEmbedding(in: cg)
    }

    /// Embeddings for every face in `image` (camera-roll scan).
    func allFaceEmbeddings(in image: UIImage) throws -> [FaceEmbedding] {
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

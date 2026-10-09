import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// macOS evaluation tool: runs the real FaceDetector (Vision + CoreML) over the fixture set on the Mac,
// where Vision landmarks work (the iOS Simulator's do not). Usage: facematch-mac <fixtures/faces dir> <out dir> [--min-recall N]

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: facematch-mac <faces dir> <out dir> [--min-recall N]"); exit(2) }
let faces = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
var minRecall: Int?
if let i = args.firstIndex(of: "--min-recall"), i + 1 < args.count { minRecall = Int(args[i + 1]) }
try FileManager.default.createDirectory(at: out.appendingPathComponent("annotated"), withIntermediateDirectories: true)

let fixtures = try JSONDecoder().decode([FaceFixture].self, from: Data(contentsOf: faces.appendingPathComponent("manifest.json")))
let detector = FaceDetector()
let maxDim = ProcessInfo.processInfo.environment["FACEMATCH_MAX_DIM"].flatMap { Double($0) }.map { CGFloat($0) } ?? FaceDetector.maxDimension
var images: [String: CGImage] = [:]
for f in fixtures {
    guard let img = FaceDetector.prepared(url: faces.appendingPathComponent(f.file), maxDimension: maxDim) else { fatalError("cannot load \(f.file)") }
    images[f.file] = img
}

// --dump-embeddings: all-face embeddings per file as JSON, for offline metric experiments (python/numpy).
if args.contains("--dump-embeddings") {
    var dump: [String: [[Float]]] = [:]
    for f in fixtures { dump[f.file] = try detector.allFaceEmbeddings(in: images[f.file]!).map(\.vector) }
    try JSONEncoder().encode(dump).write(to: out.appendingPathComponent("embeddings.json"))
}

let started = Date()
let eval = try FaceMatchEvaluation.run(
    fixtures: fixtures, threshold: FaceDetector.defaultMatchThreshold,
    embedLargest: { try detector.largestFaceEmbedding(in: images[$0.file]!) },
    embedAll: { try detector.allFaceEmbeddings(in: images[$0.file]!) },
    distances: { detector.pairwiseDistances(photoFaces: $0, enrolled: $1) })

// Alignment usage + annotated evidence images (boxes red, landmarks green/yellow; aligned crops strip).
var alignedCount = 0, faceCount = 0, undetected: [String] = []
func save(_ img: CGImage, to url: URL) {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    CGImageDestinationFinalize(d)
}
for f in fixtures {
    let img = images[f.file]!
    let diags = try detector.faceDiagnostics(in: img)
    if diags.isEmpty { undetected.append(f.file) }
    for d in diags { faceCount += 1; if d.alignedLandmarks != nil { alignedCount += 1 } }
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { continue }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setLineWidth(max(2, CGFloat(w) / 250))
    for d in diags {
        ctx.setStrokeColor(d.alignedLandmarks != nil ? CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1) : CGColor(red: 1, green: 0.6, blue: 0, alpha: 1))
        ctx.stroke(CGRect(x: d.box.minX, y: CGFloat(h) - d.box.maxY, width: d.box.width, height: d.box.height))
        if let l = d.landmarks {
            ctx.setFillColor(CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 1))
            for p in l.points { let r = max(3, CGFloat(w) / 200); ctx.fillEllipse(in: CGRect(x: p.x - r, y: CGFloat(h) - p.y - r, width: 2 * r, height: 2 * r)) }
        }
    }
    if let a = ctx.makeImage() { save(a, to: out.appendingPathComponent("annotated/\(f.file)")) }
    // model-input strip: the 112x112 crop(s) actually fed to MobileFaceNet
    let crops = try detector.allFaceCrops(in: img)
    if !crops.isEmpty, let sctx = CGContext(data: nil, width: 112 * crops.count, height: 112, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
        for (i, c) in crops.enumerated() { sctx.draw(c, in: CGRect(x: 112 * i, y: 0, width: 112, height: 112)) }
        if let s = sctx.makeImage() { save(s, to: out.appendingPathComponent("annotated/crop_\(f.file)")) }
    }
}

let report = eval.report(notes: [
    "platform: macOS Vision + CoreML (real landmarks)   faces aligned \(alignedCount)/\(faceCount)   photos with no face detected: \(undetected.count)\(undetected.isEmpty ? "" : " (" + undetected.joined(separator: ", ") + ")")",
    String(format: "wall time %.1fs", Date().timeIntervalSince(started)),
])
print(report)
try report.write(to: out.appendingPathComponent("face-match-report-mac.txt"), atomically: true, encoding: .utf8)

var failed = false
if !eval.falseMatches.isEmpty { print("GATE FAIL: false matches \(eval.falseMatches.count)"); failed = true }
let hits = eval.genuine.count - eval.missed.count
if let m = minRecall, hits < m { print("GATE FAIL: recall \(hits) < \(m)"); failed = true }
exit(failed ? 1 : 0)

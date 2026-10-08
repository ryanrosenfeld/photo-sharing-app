import XCTest
import UIKit
@testable import PhotoShare

/// Runs the same FaceDetector pipeline the Face Match Sandbox uses (Vision detect -> 25% pad crop
/// -> 112x112 -> MobileFaceNet) over committed fixture photos and reports a distance table plus
/// false / missed matches at the current threshold.
///
/// Fixtures: PhotoShareTests/Fixtures/faces/manifest.json ([{identity, file}]). Per identity the
/// first `2` photos play the friend's enrollment photos, the rest play camera-roll photos.
final class FaceMatchPipelineTests: XCTestCase {

    private struct Entry: Decodable {
        let identity: String
        let file: String
        let kind: String
        let role: String          // "enroll" | "probe"
        let identities: [String]  // ground truth: who is in the photo
    }
    private let detector = FaceDetector()
    private let threshold = FaceDetector.defaultMatchThreshold

    private struct Loaded {
        let entry: Entry
        var identity: String { entry.identity }
        var file: String { entry.file }
        let image: UIImage
    }

    private func loadFixtures() throws -> [Loaded] {
        let base = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/faces")
        let data = try Data(contentsOf: base.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode([Entry].self, from: data).map { e in
            let img = UIImage(contentsOfFile: base.appendingPathComponent(e.file).path)
            return Loaded(entry: e, image: try XCTUnwrap(img, "cannot load \(e.file)"))
        }
    }

    func testEveryFixtureYieldsA512DimEmbedding() throws {
        for f in try loadFixtures() {
            let e = try XCTUnwrap(try detector.largestFaceEmbedding(in: f.image), "no face detected in \(f.file)")
            XCTAssertEqual(e.count, 512, f.file)
            XCTAssertTrue(e.allSatisfy { $0.isFinite }, f.file)
        }
    }

    func testEmbeddingIsDeterministic() throws {
        let f = try XCTUnwrap(try loadFixtures().first)
        let a = try XCTUnwrap(try detector.largestFaceEmbedding(in: f.image))
        let b = try XCTUnwrap(try detector.largestFaceEmbedding(in: f.image))
        XCTAssertEqual(detector.pairwiseDistances(photoFaces: [a], enrolled: [b]).first ?? -1, 0, accuracy: 1e-3)
    }

    /// Scores every (probe photo, enrolled identity) pair against ground truth at the shipping threshold and
    /// writes a report: per-kind recall, false matches, distance distributions, and a threshold sweep.
    func testDistanceTableAndMatchOutcomesAtThreshold() throws {
        let fixtures = try loadFixtures()
        let identities = Array(Set(fixtures.map(\.identity))).sorted()

        var enrolled: [String: [[Float]]] = [:]
        var probes: [(entry: Entry, faces: [[Float]])] = []
        for f in fixtures {
            try autoreleasepool {
                if f.entry.role == "enroll" {
                    if let e = try detector.largestFaceEmbedding(in: f.image) { enrolled[f.identity, default: []].append(e) }
                } else {
                    probes.append((f.entry, try detector.allFaceEmbeddings(in: f.image)))
                }
            }
            print("PROGRESS \(f.file)")
        }
        XCTAssertEqual(enrolled.count, identities.count, "every identity needs at least one enrollment embedding")

        // genuine = (probe, identity actually in it); impostor = (probe, identity not in it)
        struct Pair { let file: String; let kind: String; let id: String; let genuine: Bool; let d: Float? }
        var pairs: [Pair] = []
        for probe in probes {
            for id in identities {
                let d = detector.pairwiseDistances(photoFaces: probe.faces, enrolled: enrolled[id] ?? []).first
                pairs.append(Pair(file: probe.entry.file, kind: probe.entry.kind, id: id, genuine: probe.entry.identities.contains(id), d: d))
            }
        }
        func matched(_ p: Pair) -> Bool { p.d.map { $0 < threshold } ?? false }
        let genuine = pairs.filter(\.genuine), impostor = pairs.filter { !$0.genuine }
        let missed = genuine.filter { !matched($0) }
        let falseM = impostor.filter(matched)
        func stats(_ xs: [Float]) -> String {
            guard !xs.isEmpty else { return "n/a" }
            let s = xs.sorted()
            return String(format: "min %.1f  p50 %.1f  p95 %.1f  max %.1f", s[0], s[s.count / 2], s[Int(Double(s.count - 1) * 0.95)], s[s.count - 1])
        }
        let gd = genuine.compactMap(\.d), idist = impostor.compactMap(\.d)

        var lines = ["FACE MATCH REPORT  threshold \(threshold)  identities \(identities.count)  probes \(probes.count)  genuine pairs \(genuine.count)  impostor pairs \(impostor.count)"]
        lines.append("genuine  distance: " + stats(gd) + "   undetected(no face): \(genuine.filter { $0.d == nil }.count)")
        lines.append("impostor distance: " + stats(idist))
        lines.append(String(format: "recall %d/%d = %.1f%%   false matches %d/%d", genuine.count - missed.count, genuine.count, 100 * Double(genuine.count - missed.count) / Double(genuine.count), falseM.count, impostor.count))
        lines.append("per kind (recall):")
        for kind in Array(Set(genuine.map(\.kind))).sorted() {
            let g = genuine.filter { $0.kind == kind }
            lines.append(String(format: "  %-16@ %3d/%3d   genuine %@", kind as NSString, g.filter(matched).count, g.count, stats(g.compactMap(\.d))))
        }
        lines.append("threshold sweep (recall / false matches):")
        for t in [8, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20] as [Float] {
            let r = genuine.filter { ($0.d ?? .infinity) < t }.count, f = impostor.filter { ($0.d ?? .infinity) < t }.count
            lines.append(String(format: "  t=%4.0f  recall %3d/%d  false %d", t, r, genuine.count, f))
        }
        if let lo = gd.max(), let hi = idist.min() { lines.append(String(format: "worst genuine %.2f vs closest impostor %.2f (gap %.2f)", lo, hi, hi - lo)) }
        if !falseM.isEmpty { lines.append("FALSE:  " + falseM.map { "\($0.file)~\($0.id)" }.joined(separator: ", ")) }
        if !missed.isEmpty { lines.append("MISSED: " + missed.map { "\($0.file)~\($0.id)" }.joined(separator: ", ")) }

        let report = lines.joined(separator: "\n")
        print("\n=== FACE MATCH REPORT ===\n\(report)\n=========================\n")
        let att = XCTAttachment(string: report)
        att.name = "face-match-report"
        att.lifetime = .keepAlways
        add(att)
        if let dir = ProcessInfo.processInfo.environment["VERIFY_OUTPUT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? report.write(toFile: dir + "/face-match-report.txt", atomically: true, encoding: .utf8)
        }

        // Regression gates (set from the committed baseline; tighten deliberately when the pipeline improves).
        XCTAssertEqual(falseM.count, 0, "false matches at threshold \(threshold): \(falseM.map { "\($0.file)~\($0.id)" })")
        XCTAssertGreaterThanOrEqual(genuine.count - missed.count, Self.minGenuineMatches, "recall regressed; MISSED: \(missed.map { "\($0.file)~\($0.id)" })")
    }

    /// Floor for genuine matches over the committed fixtures (see report for the current figure).
    private static let minGenuineMatches = 28

    /// Writes each fixture with detected boxes drawn (red) and the 25%-padded crop (green) to VERIFY_OUTPUT_DIR/annotated.
    func testWriteAnnotatedDetections() throws {
        guard let dir = ProcessInfo.processInfo.environment["VERIFY_OUTPUT_DIR"] else { return }
        let out = dir + "/annotated"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for f in try loadFixtures() {
            let prepared = f.image.preparedForFaceDetection()
            let boxes = try detector.faceBoxes(in: f.image)
            let w = prepared.size.width, h = prepared.size.height
            let img = UIGraphicsImageRenderer(size: prepared.size).image { ctx in
                prepared.draw(at: .zero)
                ctx.cgContext.setLineWidth(max(2, w / 200))
                for b in boxes {
                    ctx.cgContext.setStrokeColor(UIColor.red.cgColor)
                    ctx.cgContext.stroke(CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
                }
            }
            try img.jpegData(compressionQuality: 0.8)?.write(to: URL(fileURLWithPath: out + "/" + f.file))
            print("BOXES \(f.file) \(boxes.map { String(format: "[x%.2f y%.2f w%.2f h%.2f]", $0.minX, $0.minY, $0.width, $0.height) })")
        }
    }

    // MARK: - Regression tests for past sandbox bugs

    /// EXIF-rotated photo (pixels stored sideways) must be normalized to .up and still match its owner.
    func testExifRotatedPhotoIsNormalizedAndMatches() throws {
        let fixtures = try loadFixtures()
        let rotated = try XCTUnwrap(fixtures.first { $0.file == "alice_5_exif_rotated.jpg" })
        XCTAssertNotEqual(rotated.image.imageOrientation, .up, "fixture should carry a non-up EXIF orientation")
        let prepared = rotated.image.preparedForFaceDetection()
        XCTAssertEqual(prepared.imageOrientation, .up)

        let enrolled = try fixtures.filter { $0.identity == "alice" }.prefix(2)
            .compactMap { try detector.largestFaceEmbedding(in: $0.image) }
        let faces = try detector.allFaceEmbeddings(in: rotated.image)
        XCTAssertFalse(faces.isEmpty, "no face found in EXIF-rotated photo")
        XCTAssertTrue(detector.isMatch(photoFaces: faces, enrolled: enrolled))
    }

    /// Large camera-size frames are downsampled to <= 1024px (the earlier OOM bug) and crops use pixel dimensions.
    func testLargePhotoIsDownsampledAndCropUsesPixelDimensions() throws {
        let large = try XCTUnwrap(try loadFixtures().first { $0.file == "alice_6_large.jpg" })
        XCTAssertEqual(large.image.cgImage?.width, 4032)
        let prepared = large.image.preparedForFaceDetection()
        let w = try XCTUnwrap(prepared.cgImage).width, h = try XCTUnwrap(prepared.cgImage).height
        XCTAssertLessThanOrEqual(max(w, h) , 1024 * Int(prepared.scale), "longest pixel side must be downsampled")

        let crop = try XCTUnwrap(try detector.largestFaceCrop(in: large.image), "no face crop for large photo")
        let cw = try XCTUnwrap(crop.cgImage).width
        // The face is ~900px of 4032 (22%); a crop sized in points instead of pixels would be ~1/scale^2 of that.
        XCTAssertGreaterThan(Double(cw) / Double(w), 0.15, "crop too small, likely point/pixel mix-up")
        XCTAssertLessThan(Double(cw) / Double(w), 0.7, "crop too large, should be the face not the frame")
    }
}

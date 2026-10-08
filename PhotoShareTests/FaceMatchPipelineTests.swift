import XCTest
import UIKit
@testable import PhotoShare

/// Runs the same FaceDetector pipeline the Face Match Sandbox uses (Vision detect -> 25% pad crop
/// -> 112x112 -> MobileFaceNet) over committed fixture photos and reports a distance table plus
/// false / missed matches at the current threshold.
///
/// Fixtures: PhotoShareTests/Fixtures/faces/manifest.json ([{identity, file}]). Per identity the
/// first `enrollCount` photos play the friend's enrollment photos, the rest play camera-roll photos.
final class FaceMatchPipelineTests: XCTestCase {

    private struct Entry: Decodable { let identity: String; let file: String }
    private let enrollCount = 2
    private let detector = FaceDetector()
    private let threshold = FaceDetector.defaultMatchThreshold

    private struct Loaded {
        let identity: String
        let file: String
        let image: UIImage
    }

    private func loadFixtures() throws -> [Loaded] {
        let base = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/faces")
        let data = try Data(contentsOf: base.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode([Entry].self, from: data).map { e in
            let img = UIImage(contentsOfFile: base.appendingPathComponent(e.file).path)
            return Loaded(identity: e.identity, file: e.file, image: try XCTUnwrap(img, "cannot load \(e.file)"))
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

    /// Reports the full matrix; fails only if the pipeline itself breaks (no embeddings).
    func testDistanceTableAndMatchOutcomesAtThreshold() throws {
        let fixtures = try loadFixtures()
        let identities = Array(Set(fixtures.map(\.identity))).sorted()

        // Enrollment = largest-face embeddings of the first `enrollCount` photos per identity.
        var enrolled: [String: [[Float]]] = [:]
        var probes: [(identity: String, file: String, faces: [[Float]])] = []
        for id in identities {
            let photos = fixtures.filter { $0.identity == id }
            for (i, p) in photos.enumerated() {
                if i < enrollCount {
                    if let e = try detector.largestFaceEmbedding(in: p.image) { enrolled[id, default: []].append(e) }
                } else {
                    probes.append((id, p.file, try detector.allFaceEmbeddings(in: p.image)))
                }
            }
        }
        XCTAssertEqual(enrolled.count, identities.count, "every identity needs at least one enrollment embedding")
        XCTAssertFalse(probes.isEmpty)

        var lines = ["probe photo -> min distance to each enrolled identity (threshold \(threshold))"]
        lines.append("probe".padding(toLength: 12, withPad: " ", startingAt: 0) + identities.map { $0.padding(toLength: 9, withPad: " ", startingAt: 0) }.joined())
        var falseMatches: [String] = []
        var missedMatches: [String] = []
        var correct = 0
        for probe in probes {
            var row = probe.file.padding(toLength: 12, withPad: " ", startingAt: 0)
            for id in identities {
                let d = detector.pairwiseDistances(photoFaces: probe.faces, enrolled: enrolled[id] ?? []).first
                row += (d.map { String(format: "%.2f", $0) } ?? "n/a").padding(toLength: 9, withPad: " ", startingAt: 0)
                let matched = detector.isMatch(photoFaces: probe.faces, enrolled: enrolled[id] ?? [], threshold: threshold)
                let same = id == probe.identity
                switch (same, matched) {
                case (true, false): missedMatches.append("\(probe.file) vs \(id)")
                case (false, true): falseMatches.append("\(probe.file) vs \(id)")
                default: correct += 1
                }
            }
            lines.append(row)
        }
        let total = probes.count * identities.count
        lines.append("outcomes @\(threshold): correct \(correct)/\(total), false matches \(falseMatches.count), missed matches \(missedMatches.count)")
        if !falseMatches.isEmpty { lines.append("FALSE:  " + falseMatches.joined(separator: ", ")) }
        if !missedMatches.isEmpty { lines.append("MISSED: " + missedMatches.joined(separator: ", ")) }

        // Regression baseline at threshold 15 for the committed fixtures (see scripts/verify/make_fixtures.py).
        // The `_4` probes are small faces inside a wider scene, and `alice_6_large` is a 4032px frame with a
        // small off-centre face: the pipeline currently misses them. If this set changes (better OR worse),
        // review the report and update the baseline deliberately.
        let expectedMissed: Set<String> = [
            "alice_4.jpg vs alice", "bob_4.jpg vs bob", "carol_4.jpg vs carol", "dan_4.jpg vs dan",
            "alice_6_large.jpg vs alice",
        ]
        XCTAssertEqual(falseMatches, [], "false matches at threshold \(threshold)")
        XCTAssertEqual(Set(missedMatches), expectedMissed, "missed-match set changed vs baseline")

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
    }

    // MARK: - Regression tests for past sandbox bugs

    /// EXIF-rotated photo (pixels stored sideways) must be normalized to .up and still match its owner.
    func testExifRotatedPhotoIsNormalizedAndMatches() throws {
        let fixtures = try loadFixtures()
        let rotated = try XCTUnwrap(fixtures.first { $0.file == "alice_5_exif_rotated.jpg" })
        XCTAssertNotEqual(rotated.image.imageOrientation, .up, "fixture should carry a non-up EXIF orientation")
        let prepared = rotated.image.preparedForFaceDetection()
        XCTAssertEqual(prepared.imageOrientation, .up)

        let enrolled = try fixtures.filter { $0.identity == "alice" }.prefix(enrollCount)
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

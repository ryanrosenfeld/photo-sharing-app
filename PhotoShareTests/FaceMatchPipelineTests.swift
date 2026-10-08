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

    private let detector = FaceDetector()
    private let threshold = FaceDetector.defaultMatchThreshold

    private struct Loaded {
        let fixture: FaceFixture
        var identity: String { fixture.identity }
        var file: String { fixture.file }
        let image: UIImage
    }

    private func loadFixtures() throws -> [Loaded] {
        let base = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/faces")
        let data = try Data(contentsOf: base.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode([FaceFixture].self, from: data).map { e in
            let img = UIImage(contentsOfFile: base.appendingPathComponent(e.file).path)
            return Loaded(fixture: e, image: try XCTUnwrap(img, "cannot load \(e.file)"))
        }
    }

    func testEveryFixtureYieldsA512DimEmbedding() throws {
        for f in try loadFixtures() {
            let e = try XCTUnwrap(try detector.largestFaceEmbedding(in: f.image), "no face detected in \(f.file)")
            XCTAssertEqual(e.vector.count, 512, f.file)
            XCTAssertTrue(e.vector.allSatisfy { $0.isFinite }, f.file)
        }
    }

    func testEmbeddingIsDeterministic() throws {
        let f = try XCTUnwrap(try loadFixtures().first)
        let a = try XCTUnwrap(try detector.largestFaceEmbedding(in: f.image))
        let b = try XCTUnwrap(try detector.largestFaceEmbedding(in: f.image))
        XCTAssertEqual(detector.pairwiseDistances(photoFaces: [a], enrolled: [b]).first ?? -1, 0, accuracy: 1e-3)
    }

    /// Scores every (probe photo, enrolled identity) pair against ground truth at the shipping threshold and
    /// writes a report (per-kind recall, false matches, distance distributions, threshold sweep).
    /// NOTE: on the Simulator Vision's landmark detector is unusable, so this run exercises the box-crop fallback;
    /// the aligned pipeline is measured by scripts/verify/facematch-mac.sh (real Vision). See docs/face-matching.
    func testDistanceTableAndMatchOutcomesAtThreshold() throws {
        let fixtures = try loadFixtures()
        let byFile = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.file, $0) })
        let eval = try FaceMatchEvaluation.run(
            fixtures: fixtures.map(\.fixture), threshold: threshold,
            embedLargest: { try self.detector.largestFaceEmbedding(in: byFile[$0.file]!.image) },
            embedAll: { try self.detector.allFaceEmbeddings(in: byFile[$0.file]!.image) },
            distances: { self.detector.pairwiseDistances(photoFaces: $0, enrolled: $1) })
        XCTAssertEqual(eval.enrolledIdentities, eval.identities.count, "every identity needs an enrollment embedding")

        let report = eval.report(notes: ["platform: iOS Simulator (Vision landmarks unusable -> box-crop fallback)"])
        print("\n=== FACE MATCH REPORT ===\n\(report)\n=========================\n")
        let att = XCTAttachment(string: report)
        att.name = "face-match-report"
        att.lifetime = .keepAlways
        add(att)
        if let dir = ProcessInfo.processInfo.environment["VERIFY_OUTPUT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? report.write(toFile: dir + "/face-match-report.txt", atomically: true, encoding: .utf8)
        }

        // Regression gates for this (fallback) path; the aligned path has its own gates in facematch-mac.sh.
        XCTAssertEqual(eval.falseMatches.count, 0, "false matches at threshold \(threshold): \(eval.falseMatches.map { "\($0.file)~\($0.id)" })")
        XCTAssertGreaterThanOrEqual(eval.genuine.count - eval.missed.count, Self.minGenuineMatches, "recall regressed")
    }

    /// Floor for genuine matches over the committed fixtures on the Simulator (box-crop fallback path).
    private static let minGenuineMatches = 28

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

    /// Large camera-size frames are downsampled to <= 1024px (the earlier OOM bug) and still yield a usable crop.
    func testLargePhotoIsDownsampledAndYieldsModelSizedCrop() throws {
        let large = try XCTUnwrap(try loadFixtures().first { $0.file == "alice_6_large.jpg" })
        XCTAssertEqual(large.image.cgImage?.width, 4032)
        let prepared = try XCTUnwrap(large.image.preparedCGImage())
        XCTAssertLessThanOrEqual(max(prepared.width, prepared.height), 1024, "longest pixel side must be downsampled")

        let crop = try XCTUnwrap(try detector.largestFaceCrop(in: large.image), "no face crop for large photo")
        XCTAssertEqual(crop.cgImage?.width, 112)
        XCTAssertEqual(crop.cgImage?.height, 112)
    }
}

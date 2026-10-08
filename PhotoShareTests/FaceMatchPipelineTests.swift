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
}

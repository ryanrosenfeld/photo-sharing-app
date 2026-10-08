import Foundation
// FaceEmbedding comes from PhotoShare/FaceMatch/FaceDetector.swift (compiled into both the app and the mac tool)

/// Scores the face-match pipeline over the fixture manifest. Foundation-only so both the XCTest
/// (Simulator) and the macOS evaluation tool (scripts/verify/facematch-mac.sh) compile this same file.
struct FaceFixture: Decodable {
    let identity: String
    let file: String
    let kind: String
    let role: String          // "enroll" | "probe"
    let identities: [String]  // ground truth: who is in the photo
}

struct FaceMatchEvaluation {
    struct Pair { let file: String; let kind: String; let id: String; let genuine: Bool; let d: Float? }

    let threshold: Float
    let identities: [String]
    let probeCount: Int
    let pairs: [Pair]
    let enrolledIdentities: Int

    var genuine: [Pair] { pairs.filter(\.genuine) }
    var impostor: [Pair] { pairs.filter { !$0.genuine } }
    func matched(_ p: Pair) -> Bool { p.d.map { $0 < threshold } ?? false }
    var missed: [Pair] { genuine.filter { !matched($0) } }
    var falseMatches: [Pair] { impostor.filter(matched) }

    /// `embedLargest` embeds an enrollment photo (largest face); `embedAll` embeds every face in a probe photo.
    /// `distances` returns sorted pairwise distances (FaceDetector.pairwiseDistances).
    static func run(
        fixtures: [FaceFixture], threshold: Float,
        embedLargest: (FaceFixture) throws -> FaceEmbedding?,
        embedAll: (FaceFixture) throws -> [FaceEmbedding],
        distances: ([FaceEmbedding], [FaceEmbedding]) -> [Float]
    ) throws -> FaceMatchEvaluation {
        let identities = Array(Set(fixtures.map(\.identity))).sorted()
        var enrolled: [String: [FaceEmbedding]] = [:]
        var probes: [(FaceFixture, [FaceEmbedding])] = []
        for f in fixtures {
            try autoreleasepool {
                if f.role == "enroll" {
                    if let e = try embedLargest(f) { enrolled[f.identity, default: []].append(e) }
                } else {
                    probes.append((f, try embedAll(f)))
                }
            }
        }
        var pairs: [Pair] = []
        for (probe, faces) in probes {
            for id in identities {
                let d = distances(faces, enrolled[id] ?? []).first
                pairs.append(Pair(file: probe.file, kind: probe.kind, id: id, genuine: probe.identities.contains(id), d: d))
            }
        }
        return FaceMatchEvaluation(threshold: threshold, identities: identities, probeCount: probes.count, pairs: pairs, enrolledIdentities: enrolled.count)
    }

    private func stats(_ xs: [Float]) -> String {
        guard !xs.isEmpty else { return "n/a" }
        let s = xs.sorted()
        return String(format: "min %.3f  p50 %.3f  p95 %.3f  max %.3f", s[0], s[s.count / 2], s[Int(Double(s.count - 1) * 0.95)], s[s.count - 1])
    }

    /// Best achievable (recall at zero false matches) over all thresholds: how separable the two distributions are.
    var recallAtZeroFalse: (recall: Int, threshold: Float) {
        let cutoff = impostor.compactMap(\.d).min() ?? .infinity
        let t = cutoff
        return (genuine.filter { ($0.d ?? .infinity) < t }.count, t)
    }

    /// Threshold sweep points: cosine-distance scale normally, raw-Euclidean scale for the "before" ablation (threshold 15).
    private var sweep: [Float] {
        threshold > 5 ? [8, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20] : [0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8]
    }

    func report(notes: [String] = []) -> String {
        let g = genuine, im = impostor, gd = g.compactMap(\.d), idist = im.compactMap(\.d)
        var lines = ["FACE MATCH REPORT  threshold \(threshold)  identities \(identities.count)  probes \(probeCount)  genuine pairs \(g.count)  impostor pairs \(im.count)"]
        lines += notes
        lines.append("genuine  distance: " + stats(gd) + "   undetected(no face): \(g.filter { $0.d == nil }.count)")
        lines.append("impostor distance: " + stats(idist))
        lines.append(String(format: "recall %d/%d = %.1f%%   false matches %d/%d", g.count - missed.count, g.count, 100 * Double(g.count - missed.count) / Double(max(g.count, 1)), falseMatches.count, im.count))
        let z = recallAtZeroFalse
        lines.append(String(format: "best threshold with zero false matches: < %.3f  -> recall %d/%d", z.threshold, z.recall, g.count))
        lines.append("per kind (recall @\(threshold)):")
        for kind in Array(Set(g.map(\.kind))).sorted() {
            let gk = g.filter { $0.kind == kind }
            lines.append(String(format: "  %@ %3d/%3d   genuine %@", kind.padding(toLength: 15, withPad: " ", startingAt: 0), gk.filter(matched).count, gk.count, stats(gk.compactMap(\.d))))
        }
        lines.append("threshold sweep:")
        for t in sweep {
            let r = g.filter { ($0.d ?? .infinity) < t }.count, f = im.filter { ($0.d ?? .infinity) < t }.count
            lines.append(String(format: "  t=%5.2f  recall %3d/%d  false %d", t, r, g.count, f))
        }
        if let lo = gd.max(), let hi = idist.min() { lines.append(String(format: "worst genuine %.3f vs closest impostor %.3f (gap %.3f)", lo, hi, hi - lo)) }
        if !falseMatches.isEmpty { lines.append("FALSE:  " + falseMatches.map { "\($0.file)~\($0.id)" }.joined(separator: ", ")) }
        if !missed.isEmpty { lines.append("MISSED: " + missed.map { "\($0.file)~\($0.id)" }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

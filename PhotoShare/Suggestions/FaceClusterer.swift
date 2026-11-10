import Foundation

/// One face found while scanning the camera roll. Lives in memory only: embeddings never leave the device.
struct ScannedFace: Sendable {
    let assetId: String
    let takenAt: Date?
    let vector: [Float]
    /// Face box area as a fraction of the photo, to pick the clearest face as a person's tile picture.
    let areaFraction: Float
    /// Small JPEG of the face for the tile.
    let crop: Data?
}

/// A person who shows up repeatedly in the library.
struct PersonCluster: Identifiable, Sendable {
    let id: UUID
    /// Photos they appear in, newest first, without duplicates.
    var assetIds: [String]
    var crop: Data?
    var photoCount: Int { assetIds.count }
}

/// Groups face embeddings into people, with no names: the app can tell two faces are the same person, not who it is.
/// Online greedy assignment to the nearest running centroid, then a merge pass for clusters that grew toward each other.
/// Only aligned embeddings are used (box-crop fallbacks are too unreliable to group on, see FaceDetector).
struct FaceClusterer: Sendable {
    /// A face joins a cluster if its cosine distance to the centroid is below this. Stricter than the friend-match
    /// threshold (0.55) because a wrongly merged cluster is worse than a split one here.
    var joinThreshold: Float = 0.50
    /// Two clusters merge when their centroids are this close.
    var mergeThreshold: Float = 0.40
    /// A person must appear in at least this many photos to be suggested.
    var minPhotos = 3

    private struct Working {
        var sum: [Float] { didSet { centroid = Self.normalized(sum) } }
        var count: Int
        var faces: [ScannedFace]
        /// Cached: recomputing it for every comparison made clustering thousands of faces very slow.
        private(set) var centroid: [Float]
        init(sum: [Float], count: Int, faces: [ScannedFace]) {
            self.sum = sum; self.count = count; self.faces = faces
            self.centroid = Self.normalized(sum)
        }
        static func normalized(_ v: [Float]) -> [Float] {
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return n > 0 ? v.map { $0 / n } : v
        }
    }

    /// Faces already unit-normalized or not: both work. Result is sorted by photo count, largest first.
    func cluster(_ faces: [ScannedFace]) -> [PersonCluster] {
        var clusters: [Working] = []
        for face in faces {
            let v = Working.normalized(face.vector)
            var best: (index: Int, distance: Float)?
            for (i, c) in clusters.enumerated() {
                let d = Self.distance(v, c.centroid)
                if d < (best?.distance ?? .infinity) { best = (i, d) }
            }
            if let best, best.distance < joinThreshold {
                clusters[best.index].sum = zip(clusters[best.index].sum, v).map(+)
                clusters[best.index].count += 1
                clusters[best.index].faces.append(face)
            } else {
                clusters.append(Working(sum: v, count: 1, faces: [face]))
            }
        }

        var merged = true
        while merged {
            merged = false
            outer: for i in clusters.indices {
                for j in clusters.indices where j > i {
                    if Self.distance(clusters[i].centroid, clusters[j].centroid) < mergeThreshold {
                        clusters[i].sum = zip(clusters[i].sum, clusters[j].sum).map(+)
                        clusters[i].count += clusters[j].count
                        clusters[i].faces += clusters[j].faces
                        clusters.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }

        return clusters.compactMap { c -> PersonCluster? in
            var seen = Set<String>()
            let ordered = c.faces.sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
            let assets = ordered.map(\.assetId).filter { seen.insert($0).inserted }
            guard assets.count >= minPhotos else { return nil }
            let best = c.faces.max { $0.areaFraction < $1.areaFraction }
            return PersonCluster(id: UUID(), assetIds: assets, crop: best?.crop)
        }
        .sorted { $0.photoCount > $1.photoCount }
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? 1 - dot / denom : 2
    }
}

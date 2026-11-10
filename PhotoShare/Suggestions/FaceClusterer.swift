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
    /// Face box in the scanned image's pixels, with that image's size, so a tile picture can be cut later (faces read from
    /// the persistent index carry no crop).
    var box: CGRect? = nil
    var imageSize: CGSize? = nil
}

/// A person who shows up repeatedly in the library.
struct PersonCluster: Identifiable, Sendable {
    let id: UUID
    /// Photos they appear in, newest first, without duplicates.
    var assetIds: [String]
    var crop: Data?
    /// Where to cut `crop` from when it is missing: the clearest face's photo and box.
    var cropSource: CropSource? = nil
    var photoCount: Int { assetIds.count }
}

struct CropSource: Sendable, Equatable {
    let assetId: String
    let box: CGRect
    let imageSize: CGSize
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
    /// A cluster this close to the user's own face or a friend's is that person, so it is not suggested.
    var knownThreshold: Float = 0.50

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
    func cluster(_ faces: [ScannedFace], excluding known: [[Float]] = []) -> [PersonCluster] {
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
            // The user and people already friends are not suggestions.
            if known.contains(where: { Self.distance($0, c.centroid) < knownThreshold }) { return nil }
            var seen = Set<String>()
            let ordered = c.faces.sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
            let assets = ordered.map(\.assetId).filter { seen.insert($0).inserted }
            guard assets.count >= minPhotos else { return nil }
            let best = c.faces.max { $0.areaFraction < $1.areaFraction }
            var source: CropSource?
            if let f = best, f.crop == nil, let box = f.box, let size = f.imageSize {
                source = CropSource(assetId: f.assetId, box: box, imageSize: size)
            }
            return PersonCluster(id: UUID(), assetIds: assets, crop: best?.crop, cropSource: source)
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

    /// Every pass builds fresh clusters with fresh ids. Reuse the id of the earlier cluster a new one mostly overlaps
    /// (by photos), so tiles and an open invite sheet stay the same person while the scan keeps adding to them.
    static func carryIds(into new: [PersonCluster], from old: [PersonCluster]) -> [PersonCluster] {
        var taken = Set<UUID>()
        return new.map { c in
            let mine = Set(c.assetIds)
            let match = old.filter { !taken.contains($0.id) }
                .map { ($0, Set($0.assetIds).intersection(mine).count) }
                .max { $0.1 < $1.1 }
            guard let (prev, overlap) = match, overlap * 2 > min(prev.assetIds.count, c.assetIds.count) else { return c }
            taken.insert(prev.id)
            return PersonCluster(id: prev.id, assetIds: c.assetIds, crop: c.crop ?? prev.crop, cropSource: (c.crop ?? prev.crop) == nil ? c.cropSource : nil)
        }
    }
}

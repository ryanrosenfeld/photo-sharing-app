import Photos
import UIKit

/// Walks the camera roll newest first, finds faces on the device, and groups them into people. Nothing is uploaded:
/// embeddings and crops stay in memory and are gone when the screen closes.
///
/// Recent photos come first so the suggestions appear within seconds; the scan then keeps going through older photos
/// while the screen is open, at utility priority, and stops the moment it is cancelled.
@MainActor
final class CameraRollScanner: ObservableObject {
    @Published private(set) var people: [PersonCluster] = []
    @Published private(set) var scanned = 0
    @Published private(set) var total = 0
    @Published private(set) var isScanning = false
    @Published private(set) var finished = false

    /// Photos looked at before the first result is considered ready, then the rest of `maxPhotos` in the background.
    static let firstBatch = 250
    static let maxPhotos = 2_000
    private nonisolated static let imageSide: CGFloat = 1024

    private var task: Task<Void, Never>?
    private var faces: [ScannedFace] = []
    private let clusterer = FaceClusterer()

    /// Embeddings of the user and their friends; clusters matching them are left out.
    private var known: [[Float]] = []

    func start(userId: UUID?) {
        guard task == nil else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { finished = true; return }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = Self.maxPhotos
        let result = PHAsset.fetchAssets(with: .image, options: options)
        total = result.count
        isScanning = true

        task = Task { [weak self] in
            let detector = FaceDetector()
            let known = await Self.loadKnown(userId: userId, detector: detector)
            self?.known = known
            var index = 0
            while index < result.count {
                if Task.isCancelled { break }
                let asset = result.object(at: index)
                index += 1
                let found = await Self.clusterable(await FaceIndexer.shared.faces(for: asset))
                guard let self else { return }
                self.faces += found
                // Each published change re-renders the screen, so update the counter in steps.
                if index % 10 == 0 || index == result.count { self.scanned = index }
                // Refresh the tiles after the first batch, then every 100 photos.
                if index == Self.firstBatch || index % 100 == 0 { self.regroup() }
            }
            guard let self else { return }
            self.scanned = index
            await self.grouping?.value
            await self.regroup(wait: true)?.value
            self.isScanning = false
            self.finished = true
        }
    }

    func stop() {
        task?.cancel()
        grouping?.cancel()
        task = nil
        isScanning = false
    }

    private var grouping: Task<Void, Never>?

    /// Clustering thousands of faces is heavy, so it runs off the main thread on a snapshot; the main thread only
    /// swaps in the result. A pass still running when the next is due is left to finish (the next one catches up).
    @discardableResult
    private func regroup(wait: Bool = false) -> Task<Void, Never>? {
        if groupingBusy, !wait { return grouping }
        let snapshot = faces, clusterer = clusterer, known = known
        groupingBusy = true
        let t = Task { [weak self] in
            let clusters = await Task.detached(priority: .utility) { clusterer.cluster(snapshot, excluding: known) }.value
            guard let self else { return }
            // Cluster ids are regenerated each pass, so remember dismissals by their photos instead.
            let withCrops = await self.fillCrops(clusters)
            let hidden = self.hiddenAssets
            let visible = withCrops.filter { c in
                !hidden.contains { $0.intersection(c.assetIds).count * 2 > c.assetIds.count }
            }
            self.people = FaceClusterer.carryIds(into: visible, from: self.people)
            self.groupingBusy = false
        }
        grouping = t
        return t
    }
    private var groupingBusy = false

    private var hiddenAssets: [Set<String>] = []

    /// "that's me" or "not now": the tile disappears and stays gone as the scan continues.
    func hide(_ person: PersonCluster) {
        hiddenAssets.append(Set(person.assetIds))
        people.removeAll { $0.id == person.id }
    }

    /// The user's own face profile (downloaded and embedded here) plus every friend's stored enrollment.
    private nonisolated static func loadKnown(userId: UUID?, detector: FaceDetector) async -> [[Float]] {
        var vectors = FaceEnrollmentStore().allEmbeddings().map(\.vector)
        if let userId, let images = try? await FaceProfileManager().downloadPhotos(for: userId, viewer: userId) {
            let own = await Task.detached(priority: .utility) {
                images.compactMap { try? detector.largestFaceEmbedding(in: $0) }.map(\.vector)
            }.value
            vectors += own
        }
        return vectors
    }

    // MARK: - One photo

    /// Aligned, reasonably large faces only: box-crop fallbacks and tiny faces are too noisy to group people on.
    /// Photos already in the face index are not scanned again.
    private static func clusterable(_ faces: [IndexedFace]) -> [ScannedFace] {
        faces.compactMap { f in
            guard f.embedding.aligned, f.box.width >= 40 else { return nil }
            return ScannedFace(assetId: f.assetId, takenAt: f.takenAt, vector: f.embedding.vector,
                               areaFraction: f.areaFraction, crop: nil, box: f.box, imageSize: f.imageSize)
        }
    }

    /// Tile pictures are cut on demand, so the index never stores face thumbnails.
    private func fillCrops(_ people: [PersonCluster]) async -> [PersonCluster] {
        var out: [PersonCluster] = []
        for var p in people {
            if p.crop == nil, let src = p.cropSource {
                if let cached = cropCache[src.assetId + "\(src.box)"] { p.crop = cached }
                else if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [src.assetId], options: nil).firstObject,
                        let data = await Self.cropData(asset: asset, source: src) {
                    cropCache[src.assetId + "\(src.box)"] = data
                    p.crop = data
                }
            }
            out.append(p)
        }
        return out
    }
    private var cropCache: [String: Data] = [:]

    private nonisolated static func cropData(asset: PHAsset, source: CropSource) async -> Data? {
        guard let image = await FaceIndexer.loadForCrop(asset), let cg = image.preparedCGImage(maxDimension: imageSide) else { return nil }
        return crop(of: cg, box: source.box)
    }

    private nonisolated static func crop(of image: CGImage, box: CGRect) -> Data? {
        let pad = box.width * 0.35
        let rect = box.insetBy(dx: -pad, dy: -pad)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: rect.integral) else { return nil }
        let size = CGSize(width: 128, height: 128)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.7)
    }
}

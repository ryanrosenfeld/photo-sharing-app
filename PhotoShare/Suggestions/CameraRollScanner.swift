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

    func start() {
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
            var index = 0
            while index < result.count {
                if Task.isCancelled { break }
                let asset = result.object(at: index)
                index += 1
                let found = await Self.scan(asset: asset, detector: detector)
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
        let snapshot = faces, clusterer = clusterer
        groupingBusy = true
        let t = Task { [weak self] in
            let clusters = await Task.detached(priority: .utility) { clusterer.cluster(snapshot) }.value
            guard let self else { return }
            // Cluster ids are regenerated each pass, so remember dismissals by their photos instead.
            let hidden = self.hiddenAssets
            self.people = clusters.filter { c in
                !hidden.contains { $0.intersection(c.assetIds).count * 2 > c.assetIds.count }
            }
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

    // MARK: - One photo

    private nonisolated static func scan(asset: PHAsset, detector: FaceDetector) async -> [ScannedFace] {
        guard let image = await load(asset) else { return [] }
        let id = asset.localIdentifier, date = asset.creationDate
        return await Task.detached(priority: .utility) { () -> [ScannedFace] in
            guard let cg = image.preparedCGImage(maxDimension: imageSide),
                  let found = try? detector.facesWithEmbeddings(in: cg) else { return [] }
            let area = CGFloat(cg.width * cg.height)
            return found.compactMap { box, embedding in
                // Aligned faces only: box-crop fallbacks are too noisy to group people on.
                guard embedding.aligned, box.width >= 40 else { return nil }
                return ScannedFace(
                    assetId: id, takenAt: date, vector: embedding.vector,
                    areaFraction: Float(box.width * box.height / area),
                    crop: crop(of: cg, box: box)
                )
            }
        }.value
    }

    private nonisolated static func load(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false   // don't pull iCloud originals just to look for faces
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: imageSide, height: imageSide),
                contentMode: .aspectFit, options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
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

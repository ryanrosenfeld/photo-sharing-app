import BackgroundTasks
import Photos
import UIKit

/// Fills and maintains the face index: every library photo is scanned once, newest first, and saved on the phone.
/// "Progress" is just which photos already have a row, so a kill, a crash or an expired background task loses at most
/// the photo in flight and the next run carries on where this one stopped. New photos are the newest, so the same pass
/// picks them up first.
///
/// Runs in three places: while the app is open (utility priority, paused on low power / heat), in a BGProcessingTask
/// when the phone is idle and charging, and briefly after the library changes.
@MainActor
final class FaceIndexer: ObservableObject {
    static let shared = FaceIndexer()
    static let taskIdentifier = "com.ryanrosenfeld.photoshare.faceindex"

    @Published private(set) var indexed = 0
    @Published private(set) var total = 0
    @Published private(set) var isRunning = false
    /// Bumps whenever a pass finishes or the index grows by a chunk; observers re-run their matching.
    @Published private(set) var revision = 0

    let store: FaceIndexStore
    private let detector = FaceDetector()
    private var task: Task<Void, Never>?
    private nonisolated static let imageSide: CGFloat = 1024
    private nonisolated static let minFaceWidth: CGFloat = 24

    init(store: FaceIndexStore = FaceIndexStore()) { self.store = store }

    var isComplete: Bool { total > 0 && indexed >= total && !isRunning }

    /// What is left to scan, newest first. Pure so it can be tested.
    nonisolated static func pending(library: [(id: String, date: Date?)], indexed: Set<String>) -> [String] {
        library.filter { !indexed.contains($0.id) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .map(\.id)
    }

    static func canRead() -> Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    // MARK: - Running

    /// Starts (or joins) a pass over whatever is not indexed yet. `background` passes ignore the foreground throttles.
    func start(background: Bool = false) {
        guard task == nil, Self.canRead() else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.runPass(background: background)
            self?.task = nil
            self?.isRunning = false
            self?.revision += 1
        }
    }

    func stop() { task?.cancel() }

    /// Waits for the current pass; used by the background task.
    func wait() async { await task?.value }

    private func runPass(background: Bool) async {
        let library = Self.libraryAssets()
        let known = await store.indexedAssetIds()
        // Photos deleted (or hidden by limited access) since last time leave the index.
        let present = Set(library.map(\.id))
        await store.remove(assetIds: known.filter { !present.contains($0) })
        let todo = Self.pending(library: library, indexed: known.intersection(present))
        total = library.count
        indexed = library.count - todo.count
        var sinceRevision = 0
        for id in todo {
            if Task.isCancelled { return }
            if !background { await waitUntilCool() }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
            let faces = await Self.scan(asset: asset, detector: detector)
            await store.record(assetId: id, takenAt: asset.creationDate, faces: faces)
            indexed += 1
            sinceRevision += 1
            if sinceRevision >= 500 { sinceRevision = 0; revision += 1 }
        }
    }

    /// Foreground courtesy: back off while Low Power Mode is on or the phone is hot.
    private func waitUntilCool() async {
        while !Task.isCancelled,
              ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private static func libraryAssets() -> [(id: String, date: Date?)] {
        let result = PHAsset.fetchAssets(with: .image, options: nil)
        var out: [(String, Date?)] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in out.append((a.localIdentifier, a.creationDate)) }
        return out
    }

    // MARK: - One photo

    /// Faces for a photo, from the index when it is there, else scanned now and saved. Used by the suggestions screen so
    /// its work also lands in the index.
    func faces(for asset: PHAsset) async -> [IndexedFace] {
        if let cached = await store.faces(for: asset.localIdentifier) { return cached }
        let faces = await Self.scan(asset: asset, detector: detector)
        await store.record(assetId: asset.localIdentifier, takenAt: asset.creationDate, faces: faces)
        return faces
    }

    nonisolated static func scan(asset: PHAsset, detector: FaceDetector) async -> [IndexedFace] {
        guard let image = await load(asset) else { return [] }
        let id = asset.localIdentifier, date = asset.creationDate
        return await Task.detached(priority: .utility) { () -> [IndexedFace] in
            guard let cg = image.preparedCGImage(maxDimension: imageSide),
                  let found = try? detector.facesWithEmbeddings(in: cg) else { return [] }
            let size = CGSize(width: cg.width, height: cg.height)
            return found.compactMap { box, embedding in
                box.width >= minFaceWidth ? IndexedFace(assetId: id, takenAt: date, embedding: embedding, box: box, imageSize: size) : nil
            }
        }.value
    }

    nonisolated static func loadForCrop(_ asset: PHAsset) async -> UIImage? { await load(asset) }

    private nonisolated static func load(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false   // never pull iCloud originals just to look for faces
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: imageSide, height: imageSide), contentMode: .aspectFit, options: options
            ) { image, info in
                // Opportunistic delivery can call twice; with highQualityFormat there is one callback, but be safe.
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Background processing

    /// Call once at launch, before the app finishes launching.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in shared.handle(task) }
        }
    }

    /// Asks iOS for time when the phone is idle and charging. Cheap to call repeatedly.
    static func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ bg: BGProcessingTask) {
        Self.scheduleBackgroundTask()   // next window, in case this one does not finish the job
        start(background: true)
        bg.expirationHandler = { [weak self] in Task { @MainActor in self?.stop() } }
        Task {
            await wait()
            bg.setTaskCompleted(success: isComplete)
        }
    }
}

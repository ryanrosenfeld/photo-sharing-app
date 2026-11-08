import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit
import os

/// Downloads a received photo, decrypts it with the user's private key and decodes it.
///
/// Everything heavy (download, key unwrap, AES-GCM open, image decode) runs off the main actor. Concurrent requests for the
/// same photo share one task, grids/polaroids get a downsampled decode, and the still-encrypted blob is kept in the Caches
/// directory so a relaunch skips the download. Decrypted bytes live only in memory (never written to disk).
/// Photos shared before E2E encryption (no wrapped key) are plain JPEGs and pass through unchanged.
actor PhotoLoader {
    static let shared = PhotoLoader()

    enum LoadError: LocalizedError {
        case noPrivateKey
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .noPrivateKey: "This photo was encrypted for a different device. Sign in on the device you used when it was sent."
            case .notAnImage: "Could not load photo."
            }
        }
    }

    enum Size: Sendable {
        /// Downsampled for the polaroid stack.
        case thumbnail
        /// Full resolution for the detail view.
        case full

        fileprivate var maxPixelSize: Int { self == .thumbnail ? 800 : 4096 }
    }

    private struct Key: Hashable { let id: UUID; let thumbnail: Bool }

    private let memory = ImageMemoryCache()
    private var imageTasks: [Key: Task<UIImage, Error>] = [:]
    private var blobTasks: [UUID: Task<Data, Error>] = [:]
    private var prunedDisk = false
    /// At most this many blobs download at once, first requested first: on a slow link the photo on top of the stack gets the
    /// bandwidth instead of sharing it with every photo behind it.
    private static let maxConcurrentDownloads = 2
    private var activeDownloads = 0
    private var downloadWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Public API

    /// Synchronous memory-cache lookup so views can render a decoded image on their first frame.
    nonisolated func cachedImage(photoId: UUID, size: Size) -> UIImage? {
        memory.image(photoId: photoId, thumbnail: size == .thumbnail)
    }

    func image(for photo: ReceivedPhoto, size: Size = .thumbnail) async throws -> UIImage {
        let thumb = size == .thumbnail
        if let cached = memory.image(photoId: photo.photoId, thumbnail: thumb) { return cached }
        let key = Key(id: photo.photoId, thumbnail: thumb)
        if let running = imageTasks[key] { return try await running.value }
        let blobTask = blobTask(for: photo)
        let memory = memory
        let task = Task { () throws -> UIImage in
            let started = ContinuousClock.now
            let data = try await blobTask.value
            let image = try await Self.decode(data, maxPixelSize: size.maxPixelSize)
            memory.set(image, photoId: photo.photoId, thumbnail: thumb)
            PerfLog.logger.notice("[perf] \(photo.photoId.uuidString.prefix(4), privacy: .public) \(thumb ? "thumb" : "full", privacy: .public) ready after \(PerfLog.ms(since: started))ms \(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))")
            return image
        }
        imageTasks[key] = task
        defer { imageTasks[key] = nil }
        return try await task.value
    }

    /// Decrypted original bytes (for "Save to camera roll"). Not cached in memory beyond the call.
    func imageData(for photo: ReceivedPhoto) async throws -> Data {
        try await blobTask(for: photo).value
    }

    /// Warms thumbnails for the photos the user will see first. Fire and forget.
    nonisolated func prefetch(_ photos: [ReceivedPhoto], limit: Int = 6) {
        // The top photo of each sender's stack first, then the rest in feed order.
        var seen = Set<String>()
        let tops = photos.filter { seen.insert($0.photos.sender.displayName).inserted }
        let topIds = Set(tops.map(\.photoId))
        let ordered = (tops + photos.filter { !topIds.contains($0.photoId) }).prefix(limit)
        for photo in ordered {
            Task(priority: .userInitiated) { _ = try? await self.image(for: photo, size: .thumbnail) }
        }
    }

    // MARK: - Pipeline

    /// Download + decrypt, shared between concurrent requests (thumbnail and full of the same photo decrypt once).
    private func blobTask(for photo: ReceivedPhoto) -> Task<Data, Error> {
        if let running = blobTasks[photo.photoId] { return running }
        pruneDiskIfNeeded()
        let task = Task { () throws -> Data in
            await self.acquireDownloadSlot()
            let blob: Data
            do { blob = try await Self.encryptedBlob(for: photo) } catch { self.releaseDownloadSlot(); throw error }
            self.releaseDownloadSlot()
            return try await Self.decrypt(blob, for: photo)
        }
        blobTasks[photo.photoId] = task
        // Only de-duplicate while in flight; the decrypted bytes are not retained.
        Task { _ = try? await task.value; self.blobTasks[photo.photoId] = nil }
        return task
    }

    private func acquireDownloadSlot() async {
        if activeDownloads < Self.maxConcurrentDownloads { activeDownloads += 1; return }
        await withCheckedContinuation { downloadWaiters.append($0) }   // the slot is handed over, not re-counted
    }

    private func releaseDownloadSlot() {
        if downloadWaiters.isEmpty { activeDownloads -= 1 } else { downloadWaiters.removeFirst().resume() }
    }

    nonisolated private static func encryptedBlob(for photo: ReceivedPhoto) async throws -> Data {
        let file = EncryptedBlobCache.url(for: photo.photoId)
        if let data = try? Data(contentsOf: file) { return data }
        let started = ContinuousClock.now
        let blob = try await supabase.storage.from("photos").download(path: photo.photos.storagePath)
        PerfLog.logger.notice("[perf] \(photo.photoId.uuidString.prefix(4), privacy: .public) download \(PerfLog.ms(since: started))ms \(blob.count) bytes")
        if photo.wrappedKey != nil { EncryptedBlobCache.store(blob, at: file) }   // only ciphertext is ever cached
        return blob
    }

    nonisolated private static func decrypt(_ blob: Data, for photo: ReceivedPhoto) async throws -> Data {
        guard let wrapped = photo.wrappedKey else { return blob }
        let started = ContinuousClock.now
        guard let privateKey = KeyPairManager.privateKey(for: photo.recipientId),
              let wrappedData = Data(base64Encoded: wrapped)
        else { throw LoadError.noPrivateKey }
        let key = try PhotoEncryption.unwrap(wrappedData, with: privateKey)
        let unwrapped = PerfLog.ms(since: started)
        let plain = try PhotoEncryption.open(blob: blob, key: key)
        PerfLog.logger.notice("[perf] \(photo.photoId.uuidString.prefix(4), privacy: .public) keychain+unwrap \(unwrapped)ms, aes-gcm open \(PerfLog.ms(since: started) - unwrapped)ms (background)")
        return plain
    }

    /// Decodes (and downsamples) with ImageIO. `ShouldCacheImmediately` does the decode here rather than on first draw
    /// on the main thread; the transform bakes in EXIF orientation.
    nonisolated private static func decode(_ data: Data, maxPixelSize: Int) async throws -> UIImage {
        let started = ContinuousClock.now
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw LoadError.notAnImage }
        PerfLog.logger.notice("[perf] decode \(PerfLog.ms(since: started))ms (background) -> \(cg.width)x\(cg.height)")
        return UIImage(cgImage: cg)
    }

    private func pruneDiskIfNeeded() {
        guard !prunedDisk else { return }
        prunedDisk = true
        Task.detached(priority: .background) { EncryptedBlobCache.prune() }
    }
}

/// Timing logs for the photo load path (category "perf"). Read with:
/// `xcrun simctl spawn <udid> log show --last 5m --predicate 'category == "perf"' --style compact`
enum PerfLog {
    static let logger = Logger(subsystem: "com.ryanrosenfeld.photoshare", category: "perf")

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now)
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// `NSCache` is thread-safe; this wrapper makes that explicit so decoded images can be read from any isolation domain.
private final class ImageMemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

    private func key(_ id: UUID, _ thumbnail: Bool) -> NSString { "\(id.uuidString)-\(thumbnail ? "t" : "f")" as NSString }

    func image(photoId: UUID, thumbnail: Bool) -> UIImage? { cache.object(forKey: key(photoId, thumbnail)) }

    func set(_ image: UIImage, photoId: UUID, thumbnail: Bool) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key(photoId, thumbnail), cost: cost)
    }
}

/// Still-encrypted photo blobs in the Caches directory. Decrypted photos are never written to disk.
private enum EncryptedBlobCache {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("EncryptedPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for photoId: UUID) -> URL { directory.appendingPathComponent(photoId.uuidString + ".blob") }

    static func store(_ blob: Data, at url: URL) { try? blob.write(to: url, options: .atomic) }

    /// Photos expire server-side after 30 days; keep the cache to that age and ~300 MB.
    static func prune(maxAge: TimeInterval = 30 * 24 * 3600, maxBytes: Int = 300 * 1024 * 1024) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = []
        for url in files {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let date = v?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > maxAge { try? fm.removeItem(at: url); continue }
            entries.append((url, date, v?.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

enum PhotoImagePhase {
    case empty
    case success(Image)
    case failure(Error)
}

/// Drop-in for `AsyncImage` that downloads and decrypts a received photo.
/// `.thumbnail` (default) is downsampled for the stack; `.full` is for the detail view and shows the thumbnail while it loads.
struct PhotoImage<Content: View>: View {
    let photo: ReceivedPhoto
    let size: PhotoLoader.Size
    let content: (PhotoImagePhase) -> Content
    @State private var phase: PhotoImagePhase

    init(photo: ReceivedPhoto, size: PhotoLoader.Size = .thumbnail, @ViewBuilder content: @escaping (PhotoImagePhase) -> Content) {
        self.photo = photo
        self.size = size
        self.content = content
        let loader = PhotoLoader.shared
        let initial = loader.cachedImage(photoId: photo.photoId, size: size)
            ?? (size == .full ? loader.cachedImage(photoId: photo.photoId, size: .thumbnail) : nil)
        _phase = State(initialValue: initial.map { .success(Image(uiImage: $0)) } ?? .empty)
    }

    var body: some View {
        content(phase)
            .task(id: photo.photoId) {
                if let hit = PhotoLoader.shared.cachedImage(photoId: photo.photoId, size: size) {
                    phase = .success(Image(uiImage: hit))
                    return
                }
                do { phase = .success(Image(uiImage: try await PhotoLoader.shared.image(for: photo, size: size))) }
                catch is CancellationError {}
                catch {
                    PerfLog.logger.error("[perf] \(photo.photoId.uuidString.prefix(4), privacy: .public) load FAILED: \(String(describing: error), privacy: .public)")
                    phase = .failure(error)
                }
            }
    }
}

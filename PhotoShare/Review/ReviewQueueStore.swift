import Foundation

/// A photo held back for manual review. Stores only the library identifier — the pixels stay in the
/// user's library and are read again at approval time, so nothing about a queued photo leaves the device.
struct ReviewItem: Codable, Identifiable, Equatable, Sendable {
    struct Recipient: Codable, Equatable, Hashable, Sendable {
        let id: UUID
        let name: String
    }

    let id: UUID
    let assetId: String
    let takenAt: Date
    let queuedAt: Date
    var recipients: [Recipient]
}

/// Local review queue + review settings for the signed-in user. Persisted to disk, never to the server.
@MainActor
final class ReviewQueueStore: ObservableObject {
    @Published private(set) var items: [ReviewItem] = []
    @Published private(set) var settings = ReviewSettings()
    @Published private(set) var sendingIds: Set<UUID> = []
    @Published var error: String?

    private let defaults: UserDefaults
    private let directory: URL
    private var userId: UUID?

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReviewQueue", isDirectory: true)
    }

    var count: Int { items.count }

    // MARK: - Lifecycle

    /// Loads (or switches to) the signed-in user's queue and settings. Safe to call repeatedly.
    func bind(userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        settings = defaults.data(forKey: settingsKey(userId))
            .flatMap { try? JSONDecoder().decode(ReviewSettings.self, from: $0) } ?? ReviewSettings()
        items = (try? Data(contentsOf: queueURL(userId)))
            .flatMap { try? JSONDecoder.iso.decode([ReviewItem].self, from: $0) } ?? []
    }

    // MARK: - Settings (global now; per-friend override is the hook for Friend Detail)

    func setGlobalEnabled(_ enabled: Bool) {
        settings.globalEnabled = enabled
        saveSettings()
    }

    /// `nil` clears the override so the friend follows the global setting again.
    func setOverride(_ value: Bool?, for friendId: UUID) {
        settings.friendOverrides[friendId.uuidString] = value
        saveSettings()
    }

    // MARK: - Queue

    /// Adds a matched photo. A photo already queued (same library asset) gains any new recipients instead of
    /// appearing twice.
    func enqueue(assetId: String, takenAt: Date, recipients: [ReviewItem.Recipient], now: Date = Date()) {
        guard !recipients.isEmpty else { return }
        if let idx = items.firstIndex(where: { $0.assetId == assetId }) {
            let known = Set(items[idx].recipients.map(\.id))
            items[idx].recipients += recipients.filter { !known.contains($0.id) }
        } else {
            items.append(ReviewItem(id: UUID(), assetId: assetId, takenAt: takenAt, queuedAt: now, recipients: recipients))
        }
        saveQueue()
    }

    /// Discards the photo from the queue. The library photo is untouched and nothing is uploaded.
    func reject(_ item: ReviewItem) {
        remove(item)
    }

    func rejectAll() {
        items.removeAll()
        saveQueue()
    }

    /// Sends the photo to `recipientIds` (a subset of the matched friends); the rest are dropped.
    /// On failure the item stays queued so nothing is lost.
    @discardableResult
    func approve(_ item: ReviewItem, to recipientIds: Set<UUID>, senderId: UUID) async -> Bool {
        guard !sendingIds.contains(item.id) else { return false }
        let ids = item.recipients.map(\.id).filter(recipientIds.contains)
        guard !ids.isEmpty else { remove(item); return true }

        sendingIds.insert(item.id)
        defer { sendingIds.remove(item.id) }
        do {
            try await ShareUploader.send(assetId: item.assetId, senderId: senderId, recipientIds: ids)
            remove(item)
            return true
        } catch ShareUploader.ShareError.assetUnavailable {
            remove(item)
            error = "A photo was deleted from your library, so it was removed from the queue."
            return false
        } catch {
            self.error = "Couldn't send. The photo is still in your queue — try again."
            return false
        }
    }

    func approveAll(senderId: UUID) async {
        for item in items {
            await approve(item, to: Set(item.recipients.map(\.id)), senderId: senderId)
        }
    }

    // MARK: - Persistence

    private func remove(_ item: ReviewItem) {
        items.removeAll { $0.id == item.id }
        saveQueue()
    }

    private func saveQueue() {
        guard let userId else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(items) {
            try? data.write(to: queueURL(userId), options: .atomic)
        }
    }

    private func saveSettings() {
        guard let userId, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey(userId))
    }

    private func queueURL(_ userId: UUID) -> URL {
        directory.appendingPathComponent("\(userId.uuidString).json")
    }

    private func settingsKey(_ userId: UUID) -> String { "reviewSettings_v1_\(userId.uuidString)" }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

import Foundation

/// A photo that has already been cleared to send (auto-share, or approved in the review queue) but couldn't be
/// delivered to some friends because they haven't published an encryption key yet. Like the review queue it holds
/// only the library identifier; the photo is read again when the retry happens.
struct PendingShare: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let assetId: String
    let queuedAt: Date
    var recipientIds: [UUID]
}

/// Device-local retry list for photos that were skipped for lack of a recipient key. Retried whenever the app opens
/// or returns to the foreground; a recipient who is no longer a friend (or turned Send/Receive off) is dropped.
@MainActor
final class PendingShareStore: ObservableObject {
    static let shared = PendingShareStore()

    @Published private(set) var items: [PendingShare] = []

    private let directory: URL
    private var userId: UUID?
    private var isRetrying = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingShares", isDirectory: true)
    }

    func bind(userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        items = (try? Data(contentsOf: fileURL(userId)))
            .flatMap { try? Self.decoder.decode([PendingShare].self, from: $0) } ?? []
    }

    /// Records recipients still owed `assetId`. The same photo gains recipients instead of appearing twice.
    func add(assetId: String, recipientIds: [UUID], now: Date = Date()) {
        guard !recipientIds.isEmpty else { return }
        if let idx = items.firstIndex(where: { $0.assetId == assetId }) {
            let known = Set(items[idx].recipientIds)
            items[idx].recipientIds += recipientIds.filter { !known.contains($0) }
        } else {
            items.append(PendingShare(id: UUID(), assetId: assetId, queuedAt: now, recipientIds: recipientIds))
        }
        save()
    }

    /// Drops recipients who are not in `allowed` (no longer friends, or sending to them is off); empty entries go.
    func prune(keeping allowed: Set<UUID>) {
        let before = items
        for idx in items.indices { items[idx].recipientIds.removeAll { !allowed.contains($0) } }
        items.removeAll { $0.recipientIds.isEmpty }
        if items != before { save() }
    }

    /// Sends what can be sent now. Entries whose friends still have no key are left alone without touching the photo.
    func retry(senderId: UUID, friends: [Friend]) async {
        guard !isRetrying, !items.isEmpty, !friends.isEmpty else { return }
        isRetrying = true
        defer { isRetrying = false }

        prune(keeping: Set(friends.filter { $0.mySend && $0.theirReceive }.map(\.friendId)))
        guard !items.isEmpty,
              let keys = try? await KeyPairManager.publicKeys(for: Array(Set(items.flatMap(\.recipientIds))))
        else { return }

        for item in items {
            let ready = item.recipientIds.filter { keys[$0] != nil }
            guard !ready.isEmpty else { continue }
            let waiting = item.recipientIds.filter { keys[$0] == nil }
            // Take the entry out first: `send` re-records anyone it still has to skip.
            remove(item)
            do {
                try await ShareUploader.send(assetId: item.assetId, senderId: senderId, recipientIds: ready, pending: self)
            } catch ShareUploader.ShareError.assetUnavailable {
                // Photo deleted from the library: nothing left to send.
            } catch {
                add(assetId: item.assetId, recipientIds: ready, now: item.queuedAt)   // offline etc.: try again later
            }
            add(assetId: item.assetId, recipientIds: waiting, now: item.queuedAt)
        }
    }

    private func remove(_ item: PendingShare) {
        items.removeAll { $0.id == item.id }
        save()
    }

    private func save() {
        guard let userId else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(items) { try? data.write(to: fileURL(userId), options: .atomic) }
    }

    private func fileURL(_ userId: UUID) -> URL { directory.appendingPathComponent("\(userId.uuidString).json") }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

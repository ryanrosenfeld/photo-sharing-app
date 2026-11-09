import Foundation

/// Photos picked on the suggestions screen to go to someone once they accept the invite. Device-local, and holds only
/// library identifiers (never pixels or embeddings). When the invite is accepted the photos are handed to the usual
/// send path, which honours review mode.
struct InvitedPhotos: Codable, Equatable, Sendable {
    let code: String
    var assetIds: [String]
    let createdAt: Date
}

enum InvitedPhotosStore {
    private static let key = "invite.queuedPhotos"
    /// Past photos are a welcome gift, not a bulk upload: newest first, capped.
    static let maxPhotos = 50

    static func all(defaults: UserDefaults = .standard) -> [InvitedPhotos] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([InvitedPhotos].self, from: $0) } ?? []
    }

    static func add(code: String, assetIds: [String], now: Date = Date(), defaults: UserDefaults = .standard) {
        let ids = Array(assetIds.prefix(maxPhotos))
        guard !ids.isEmpty else { return }
        var items = all(defaults: defaults).filter { $0.code != code }
        items.append(InvitedPhotos(code: code, assetIds: ids, createdAt: now))
        save(Array(items.suffix(20)), defaults: defaults)
    }

    static func remove(code: String, defaults: UserDefaults = .standard) {
        save(all(defaults: defaults).filter { $0.code != code }, defaults: defaults)
    }

    /// Drops entries whose invite can no longer be accepted.
    static func prune(olderThan age: TimeInterval = 15 * 86_400, now: Date = Date(), defaults: UserDefaults = .standard) {
        save(all(defaults: defaults).filter { now.timeIntervalSince($0.createdAt) < age }, defaults: defaults)
    }

    private static func save(_ items: [InvitedPhotos], defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }
}

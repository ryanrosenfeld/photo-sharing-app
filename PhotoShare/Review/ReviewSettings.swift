import Foundation

/// Manual-review preferences. Device-local and per signed-in user: the decision to hold a photo back
/// never involves the server.
///
/// Per-friend hook: `friendOverrides` already wins over the global setting, so the friends workstream only
/// has to call `ReviewQueueStore.setOverride(_:for:)` from the Friend Detail toggle. Nothing else changes.
struct ReviewSettings: Codable, Equatable, Sendable {
    var globalEnabled = false
    /// Friend id (UUID string) -> explicit choice. Missing = follow the global setting.
    var friendOverrides: [String: Bool] = [:]

    func requiresReview(for friendId: UUID) -> Bool {
        friendOverrides[friendId.uuidString] ?? globalEnabled
    }

    /// Splits matched friends into "send right away" and "hold for review". Order is preserved.
    func partition(_ friendIds: [UUID]) -> (sendNow: [UUID], toReview: [UUID]) {
        (friendIds.filter { !requiresReview(for: $0) }, friendIds.filter { requiresReview(for: $0) })
    }
}

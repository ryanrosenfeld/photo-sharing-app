import Foundation

/// Finds a new friend's past photos in the face index. Pure so it can be unit tested without a library.
enum FaceIndexMatcher {
    struct Match: Equatable, Sendable { let assetId: String; let takenAt: Date? }

    /// Photos (newest first, as given) where `enrolled` matches a face, minus ones already sent. Uses the same rule as live
    /// auto-share (`FaceDetector.isMatch`), so a friend is recognised the same way in old photos as in new ones.
    static func matches(
        enrolled: [FaceEmbedding],
        in photos: [(assetId: String, takenAt: Date?, faces: [IndexedFace])],
        excluding sent: Set<String> = [],
        detector: FaceDetector = FaceDetector()
    ) -> [Match] {
        guard !enrolled.isEmpty else { return [] }
        return photos.compactMap { p in
            guard !sent.contains(p.assetId),
                  detector.isMatch(photoFaces: p.faces.map(\.embedding), enrolled: enrolled) else { return nil }
            return Match(assetId: p.assetId, takenAt: p.takenAt)
        }
    }
}

/// The "wow" first moment: when a friendship forms and their face profile is readable on this phone, look through the
/// whole index for them and offer all past photos at once.
///
/// - Review on for that friend: the matches go straight into the review queue (nothing leaves the phone until approved).
/// - Review off: an offer card appears ("found N photos of troy"); one tap sends them. Years of photos are never uploaded
///   without that tap.
/// - Only friendships formed after this feature first ran get an offer; existing friends are seeded as done.
@MainActor
final class PastPhotosOffers: ObservableObject {
    enum State: Codable, Equatable { case pending, done }

    struct Offer: Identifiable, Equatable {
        let friendId: UUID
        let name: String
        let matches: [FaceIndexMatcher.Match]
        /// False while the backfill is still running: the count can still grow.
        let final: Bool
        var id: UUID { friendId }
    }

    @Published private(set) var offers: [Offer] = []
    @Published private(set) var sending: Set<UUID> = []

    private var states: [UUID: State] = [:]
    private var seeded = false
    private var userId: UUID?
    private let defaults: UserDefaults
    private var busy = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var key: String { "pastPhotos_v1_\(userId?.uuidString ?? "none")" }
    private struct Saved: Codable { var states: [String: State] }

    func bind(userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            states = Dictionary(uniqueKeysWithValues: saved.states.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
            seeded = true
        } else { states = [:]; seeded = false }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(Saved(states: Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) }))), forKey: key)
    }

    /// Which friends still need a look: new since the feature started, not yet handled. Pure.
    nonisolated static func pendingFriends(current: [UUID], states: [UUID: State], seeded: Bool) -> (seedAsDone: [UUID], pending: [UUID]) {
        if !seeded { return (current, []) }
        return ([], current.filter { states[$0] == nil || states[$0] == .pending })
    }

    /// Call after enrollment sync, on foreground, and when the index grows.
    func refresh(friends: [Friend], review: ReviewQueueStore, indexer: FaceIndexer, enrollmentStore: FaceEnrollmentStore = FaceEnrollmentStore()) async {
        guard userId != nil, !busy else { return }
        busy = true
        defer { busy = false }

        let plan = Self.pendingFriends(current: friends.map(\.friendId), states: states, seeded: seeded)
        if !seeded { seeded = true; plan.seedAsDone.forEach { states[$0] = .done }; save() }
        for id in plan.pending where states[id] == nil { states[id] = .pending }

        let wanted = friends.filter { plan.pending.contains($0.friendId) && $0.mySend && $0.theirReceive }
        guard !wanted.isEmpty else { offers = []; return }
        let photos = await indexer.store.facesByAsset()
        var next: [Offer] = []
        for friend in wanted {
            guard let enrolled = enrollmentStore.load(for: friend.friendId) else { continue }   // key not here yet
            let sent = await indexer.store.sentAssetIds(to: friend.friendId)
            let matches = await Task.detached(priority: .utility) {
                FaceIndexMatcher.matches(enrolled: enrolled, in: photos, excluding: sent)
            }.value
            let final = indexer.isComplete
            if review.settings.requiresReview(for: friend.friendId) {
                // Held on the phone, so it is safe to queue as soon as the search is complete.
                guard final else { continue }
                for m in matches {
                    review.enqueue(assetId: m.assetId, takenAt: m.takenAt ?? Date(), recipients: [.init(id: friend.friendId, name: friend.displayName)])
                }
                await indexer.store.markSent(assetIds: matches.map(\.assetId), to: friend.friendId)
                states[friend.friendId] = .done
                save()
            } else if !matches.isEmpty {
                next.append(Offer(friendId: friend.friendId, name: friend.displayName, matches: matches, final: final))
            } else if final {
                states[friend.friendId] = .done
                save()
            }
        }
        offers = next
    }

    /// "send them": hands every match to the normal send path, which encrypts, retries when the friend's key is missing,
    /// and survives a relaunch.
    func accept(_ offer: Offer, pending: PendingShareStore = .shared, senderId: UUID, friends: [Friend], indexer: FaceIndexer) async {
        sending.insert(offer.friendId)
        for m in offer.matches { pending.add(assetId: m.assetId, recipientIds: [offer.friendId]) }
        await indexer.store.markSent(assetIds: offer.matches.map(\.assetId), to: offer.friendId)
        states[offer.friendId] = .done
        save()
        offers.removeAll { $0.friendId == offer.friendId }
        sending.remove(offer.friendId)
        await pending.retry(senderId: senderId, friends: friends)
    }

    func dismiss(_ offer: Offer) {
        states[offer.friendId] = .done
        save()
        offers.removeAll { $0.friendId == offer.friendId }
    }

    func reset() { offers = []; states = [:]; seeded = false; userId = nil }
}

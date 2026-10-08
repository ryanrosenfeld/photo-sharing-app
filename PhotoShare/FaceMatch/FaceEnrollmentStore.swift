import Foundation

// Persists face embeddings locally per friend.
// Embeddings are 512-D float vectors from MobileFaceNet, stored as JSON.
// They never leave the device — this is the hard privacy constraint.
//
// Key prefix is "face_enrollment_v3_": v2 held embeddings from the padded-box crop pipeline, which are not
// comparable with landmark-aligned embeddings (v1 was VNFeaturePrintObservation data). Bumping it makes every
// friend show as not enrolled until re-enrolled, instead of silently matching against stale vectors.
struct FaceEnrollmentStore: Sendable {
    private static let keyPrefix = "face_enrollment_v3_"

    func save(_ embeddings: [FaceEmbedding], for friendId: UUID) throws {
        let data = try JSONEncoder().encode(embeddings)
        UserDefaults.standard.set(data, forKey: key(for: friendId))
    }

    func load(for friendId: UUID) -> [FaceEmbedding]? {
        guard let data = UserDefaults.standard.data(forKey: key(for: friendId)) else { return nil }
        return try? JSONDecoder().decode([FaceEmbedding].self, from: data)
    }

    func hasEnrollment(for friendId: UUID) -> Bool {
        UserDefaults.standard.data(forKey: key(for: friendId)) != nil
    }

    func remove(for friendId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: friendId))
    }

    /// Remove embeddings for everyone not in `friendIds` (e.g. they unfriended me).
    func prune(keeping friendIds: Set<UUID>) {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            let id = UUID(uuidString: String(key.dropFirst(Self.keyPrefix.count)))
            if let id, !friendIds.contains(id) { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func key(for friendId: UUID) -> String {
        "\(Self.keyPrefix)\(friendId.uuidString)"
    }
}

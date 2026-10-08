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

    func save(_ embeddings: [[Float]], for friendId: UUID) throws {
        let data = try JSONEncoder().encode(embeddings)
        UserDefaults.standard.set(data, forKey: key(for: friendId))
    }

    func load(for friendId: UUID) -> [[Float]]? {
        guard let data = UserDefaults.standard.data(forKey: key(for: friendId)) else { return nil }
        return try? JSONDecoder().decode([[Float]].self, from: data)
    }

    func hasEnrollment(for friendId: UUID) -> Bool {
        UserDefaults.standard.data(forKey: key(for: friendId)) != nil
    }

    func remove(for friendId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: friendId))
    }

    private func key(for friendId: UUID) -> String {
        "\(Self.keyPrefix)\(friendId.uuidString)"
    }
}

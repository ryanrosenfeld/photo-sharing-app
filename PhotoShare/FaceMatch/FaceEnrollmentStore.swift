import Foundation

// Persists face embeddings locally per friend.
// Embeddings are 128-D float vectors from MobileFaceNet, stored as JSON.
// They never leave the device — this is the hard privacy constraint.
//
// Key prefix is "face_enrollment_v2_" to avoid collisions with the old
// VNFeaturePrintObservation data stored under "face_enrollment_".
struct FaceEnrollmentStore: Sendable {
    private static let keyPrefix = "face_enrollment_v2_"

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

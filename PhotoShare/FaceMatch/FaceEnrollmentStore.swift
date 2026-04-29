import Foundation
import Vision

// Persists face embeddings locally per friend.
// Embeddings are VNFeaturePrintObservation values archived via NSKeyedArchiver.
// They never leave the device — this is the hard privacy constraint.
struct FaceEnrollmentStore: Sendable {
    private static let keyPrefix = "face_enrollment_"

    func save(_ observations: [VNFeaturePrintObservation], for friendId: UUID) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: observations as NSArray,
            requiringSecureCoding: true
        )
        UserDefaults.standard.set(data, forKey: key(for: friendId))
    }

    func load(for friendId: UUID) -> [VNFeaturePrintObservation]? {
        guard let data = UserDefaults.standard.data(forKey: key(for: friendId)) else { return nil }
        guard let array = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, VNFeaturePrintObservation.self],
            from: data
        ) as? NSArray else { return nil }
        return array.compactMap { $0 as? VNFeaturePrintObservation }
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

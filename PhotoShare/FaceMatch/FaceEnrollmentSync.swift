import Foundation
import UIKit

/// Where a friend stands for face matching on this phone. Shown on the friend's row instead of an "Enroll" button.
enum EnrollmentStatus: Equatable, Sendable {
    case ready             // embeddings from their current face profile are on this phone
    case settingUp         // downloading + embedding right now
    case waitingForThem    // their profile is encrypted and their phone hasn't shared the key yet (next time they open otto)
    case noFaceProfile     // they haven't uploaded reference photos
    case failed            // download or face detection failed; retried next time the app opens
}

/// Automatic enrollment (SPEC "Enrollment flow"): on launch, on foreground, and whenever the friend list changes,
/// every friend whose face profile this phone can read is enrolled, and re-enrolled when they replace their photos.
/// Reference photos are decrypted in memory, turned into embeddings on-device, and discarded. Nothing is uploaded.
@MainActor
final class FaceEnrollmentSync: ObservableObject {
    @Published private(set) var statuses: [UUID: EnrollmentStatus] = [:]

    private let store = FaceEnrollmentStore()
    private let profiles = FaceProfileManager()
    private let detector = FaceDetector()
    private var running = false
    private var rerun = false
    private var forced: Set<UUID> = []

    /// What to do for one friend, decided from the server's answer and what this phone already holds. Pure, unit-tested.
    enum Plan: Equatable {
        case done(EnrollmentStatus)
        case enroll(version: String)
    }

    nonisolated static func plan(availability: FaceProfileManager.Availability, storedVersion: String?,
                                 hasEnrollment: Bool, force: Bool) -> Plan {
        switch availability {
        case .none:
            return .done(.noFaceProfile)
        case .waitingForKey:
            // Keep using what we have (an older version still matches them); otherwise wait for their key.
            return .done(hasEnrollment ? .ready : .waitingForThem)
        case .available(let version):
            if hasEnrollment && storedVersion == version && !force { return .done(.ready) }
            return .enroll(version: version)
        }
    }

    func status(for friend: Friend) -> EnrollmentStatus? { statuses[friend.friendId] }

    /// Re-download and re-embed one friend (Friend detail → "Refresh").
    func refresh(_ friend: Friend, viewer: UUID, friends: [Friend]) async {
        forced.insert(friend.friendId)
        await sync(viewer: viewer, friends: friends)
    }

    func sync(viewer: UUID, friends: [Friend]) async {
        if running { rerun = true; return }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            await syncOnce(viewer: viewer, friends: friends)
        } while rerun
    }

    private func syncOnce(viewer: UUID, friends: [Friend]) async {
        statuses = statuses.filter { id, _ in friends.contains { $0.friendId == id } }
        for friend in friends {
            let id = friend.friendId
            let availability: FaceProfileManager.Availability
            do {
                availability = try await profiles.availability(of: id, viewer: viewer)
            } catch {
                // Offline: keep whatever we had; a friend we already enrolled still matches.
                statuses[id] = store.hasEnrollment(for: id) ? .ready : .failed
                continue
            }
            let force = forced.remove(id) != nil
            switch Self.plan(availability: availability, storedVersion: store.version(for: id),
                             hasEnrollment: store.hasEnrollment(for: id), force: force) {
            case .done(let status):
                statuses[id] = status
            case .enroll(let version):
                statuses[id] = .settingUp
                statuses[id] = await enroll(id, version: version, viewer: viewer)
            }
        }
    }

    private func enroll(_ friendId: UUID, version: String, viewer: UUID) async -> EnrollmentStatus {
        let hadEnrollment = store.hasEnrollment(for: friendId)
        do {
            let images = try await profiles.downloadPhotos(for: friendId, viewer: viewer)
            let embeddings = await Task.detached(priority: .utility) { [detector] in
                images.compactMap { try? detector.largestFaceEmbedding(in: $0) }
            }.value
            // Same bar as the onboarding check that accepted these photos: at least two usable faces.
            guard embeddings.count >= 2 else {
                print("[Enrollment] \(friendId): only \(embeddings.count) usable face(s) in \(images.count) photo(s)")
                return hadEnrollment ? .ready : .failed
            }
            try store.save(embeddings, for: friendId, version: version)
            print("[Enrollment] \(friendId): enrolled from \(embeddings.count) reference photo(s)")
            return .ready
        } catch FaceProfileManager.FaceProfileError.keyNotShared {
            return hadEnrollment ? .ready : .waitingForThem
        } catch {
            print("[Enrollment] \(friendId): \(error)")
            return hadEnrollment ? .ready : .failed
        }
    }
}

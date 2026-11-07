import XCTest
@testable import PhotoShare

/// Automatic enrollment decisions (FaceEnrollmentSync.plan): when to download + embed a friend's face profile.
final class EnrollmentPlanTests: XCTestCase {
    private func plan(_ a: FaceProfileManager.Availability, stored: String? = nil, has: Bool = false, force: Bool = false)
        -> FaceEnrollmentSync.Plan {
        FaceEnrollmentSync.plan(availability: a, storedVersion: stored, hasEnrollment: has, force: force)
    }

    func testNewFriendWithReadableProfileIsEnrolled() {
        XCTAssertEqual(plan(.available(version: "key:1")), .enroll(version: "key:1"))
    }

    func testSameVersionIsNotRedone() {
        XCTAssertEqual(plan(.available(version: "key:1"), stored: "key:1", has: true), .done(.ready))
    }

    func testReplacedPhotosAreReEnrolled() {
        XCTAssertEqual(plan(.available(version: "key:2"), stored: "key:1", has: true), .enroll(version: "key:2"))
    }

    func testManualEnrollmentWithoutVersionIsReplacedByProfile() {
        XCTAssertEqual(plan(.available(version: "legacy:a"), stored: nil, has: true), .enroll(version: "legacy:a"))
    }

    func testRefreshForcesReEnrollment() {
        XCTAssertEqual(plan(.available(version: "key:1"), stored: "key:1", has: true, force: true), .enroll(version: "key:1"))
    }

    func testWaitingForTheirKey() {
        XCTAssertEqual(plan(.waitingForKey), .done(.waitingForThem))
        XCTAssertEqual(plan(.waitingForKey, stored: "key:1", has: true), .done(.ready), "old embeddings keep working")
    }

    func testNoFaceProfile() {
        XCTAssertEqual(plan(.none), .done(.noFaceProfile))
    }

    func testVersionIsStoredAndPrunedWithEmbeddings() throws {
        let store = FaceEnrollmentStore()
        let friend = UUID()
        let e = FaceEmbedding(vector: [Float](repeating: 0.1, count: 512), aligned: true)
        try store.save([e, e], for: friend, version: "key:abc")
        XCTAssertEqual(store.version(for: friend), "key:abc")
        store.prune(keeping: [])
        XCTAssertNil(store.version(for: friend))
        XCTAssertFalse(store.hasEnrollment(for: friend))
    }
}

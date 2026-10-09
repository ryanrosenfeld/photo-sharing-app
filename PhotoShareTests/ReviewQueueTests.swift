import XCTest
@testable import PhotoShare

@MainActor
final class ReviewQueueTests: XCTestCase {
    private let user = UUID()
    private let bob = ReviewItem.Recipient(id: UUID(), name: "Bob")
    private let carol = ReviewItem.Recipient(id: UUID(), name: "Carol")
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "review-tests-\(UUID().uuidString)")
    }

    private func makeStore() -> ReviewQueueStore {
        let s = ReviewQueueStore(defaults: defaults, directory: dir)
        s.bind(userId: user)
        return s
    }

    func testDefaultIsAutoSend() {
        let s = ReviewSettings()
        XCTAssertFalse(s.requiresReview(for: bob.id))
        let split = s.partition([bob.id, carol.id])
        XCTAssertEqual(split.sendNow, [bob.id, carol.id])
        XCTAssertTrue(split.toReview.isEmpty)
    }

    func testGlobalReviewHoldsEveryone() {
        var s = ReviewSettings(); s.globalEnabled = true
        let split = s.partition([bob.id, carol.id])
        XCTAssertTrue(split.sendNow.isEmpty)
        XCTAssertEqual(split.toReview, [bob.id, carol.id])
    }

    func testPerFriendOverrideBeatsGlobalBothWays() {
        var s = ReviewSettings()
        s.friendOverrides[carol.id.uuidString] = true          // review only Carol
        XCTAssertEqual(s.partition([bob.id, carol.id]).sendNow, [bob.id])
        XCTAssertEqual(s.partition([bob.id, carol.id]).toReview, [carol.id])
        s.globalEnabled = true
        s.friendOverrides[bob.id.uuidString] = false           // auto-send to Bob despite global review
        XCTAssertEqual(s.partition([bob.id, carol.id]).sendNow, [bob.id])
        XCTAssertEqual(s.partition([bob.id, carol.id]).toReview, [carol.id])
    }

    func testEnqueueDedupesByAssetAndMergesRecipients() {
        let s = makeStore()
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [bob])
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [bob, carol])
        s.enqueue(assetId: "B", takenAt: Date(), recipients: [bob])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.items[0].recipients, [bob, carol])
    }

    func testEnqueueWithNoRecipientsIsIgnored() {
        let s = makeStore()
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [])
        XCTAssertEqual(s.count, 0)
    }

    func testRejectRemovesWithoutUploading() {
        let s = makeStore()
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [bob])
        s.reject(s.items[0])
        XCTAssertEqual(s.count, 0)
    }

    func testQueueAndSettingsPersistAcrossRelaunch() {
        let s = makeStore()
        s.setGlobalEnabled(true)
        s.setOverride(false, for: bob.id)
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [carol])

        let relaunched = makeStore()
        XCTAssertTrue(relaunched.settings.globalEnabled)
        XCTAssertFalse(relaunched.settings.requiresReview(for: bob.id))
        XCTAssertEqual(relaunched.items.map(\.assetId), ["A"])
    }

    func testQueueIsPerUser() {
        let s = makeStore()
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [bob])
        let other = ReviewQueueStore(defaults: defaults, directory: dir)
        other.bind(userId: UUID())
        XCTAssertEqual(other.count, 0)
        XCTAssertFalse(other.settings.globalEnabled)
    }

    func testRejectAllClearsPersistedQueue() {
        let s = makeStore()
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [bob])
        s.enqueue(assetId: "B", takenAt: Date(), recipients: [bob])
        s.rejectAll()
        XCTAssertEqual(makeStore().count, 0)
    }

    func testApproveWithNoSelectedRecipientsDiscardsWithoutNetwork() async {
        let s = makeStore()
        s.enqueue(assetId: "A", takenAt: Date(), recipients: [bob])
        let ok = await s.approve(s.items[0], to: [], senderId: user)
        XCTAssertTrue(ok)
        XCTAssertEqual(s.count, 0)
    }
}

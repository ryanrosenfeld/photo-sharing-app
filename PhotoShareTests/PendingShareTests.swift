import XCTest
@testable import PhotoShare

@MainActor
final class PendingShareTests: XCTestCase {
    private let user = UUID()
    private let bob = UUID()
    private let carol = UUID()
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)")
    }

    private func makeStore() -> PendingShareStore {
        let s = PendingShareStore(directory: dir)
        s.bind(userId: user)
        return s
    }

    func testAddMergesRecipientsForTheSamePhoto() {
        let s = makeStore()
        s.add(assetId: "A", recipientIds: [bob])
        s.add(assetId: "A", recipientIds: [bob, carol])
        s.add(assetId: "B", recipientIds: [bob])
        s.add(assetId: "C", recipientIds: [])
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.items[0].recipientIds, [bob, carol])
    }

    func testPersistsAcrossRelaunch() {
        makeStore().add(assetId: "A", recipientIds: [bob])
        XCTAssertEqual(makeStore().items.map(\.assetId), ["A"])
    }

    func testPruneDropsFormerFriendsAndEmptyEntries() {
        let s = makeStore()
        s.add(assetId: "A", recipientIds: [bob, carol])
        s.add(assetId: "B", recipientIds: [carol])
        s.prune(keeping: [bob])
        XCTAssertEqual(s.items.map(\.assetId), ["A"])
        XCTAssertEqual(s.items[0].recipientIds, [bob])
    }
}

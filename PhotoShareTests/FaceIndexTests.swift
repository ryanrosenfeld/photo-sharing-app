import XCTest
@testable import PhotoShare

final class FaceIndexTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)/index.sqlite")
    }

    private func vec(_ axis: Int, jitter: Float = 0) -> FaceEmbedding {
        var v = [Float](repeating: 0, count: 512)
        v[axis] = 1; v[(axis + 1) % 512] = jitter
        return FaceEmbedding(vector: v, aligned: true)
    }

    private func face(_ asset: String, _ axis: Int, day: Int = 0) -> IndexedFace {
        IndexedFace(assetId: asset, takenAt: Date(timeIntervalSince1970: Double(day) * 86_400), embedding: vec(axis),
                    box: CGRect(x: 10, y: 20, width: 100, height: 120), imageSize: CGSize(width: 1000, height: 800))
    }

    func testFacesSurviveReopen() async {
        let a = FaceIndexStore(url: url)
        await a.record(assetId: "A", takenAt: nil, faces: [face("A", 3), face("A", 4)])
        await a.record(assetId: "B", takenAt: nil, faces: [])
        let b = FaceIndexStore(url: url)
        let ids = await b.indexedAssetIds()
        XCTAssertEqual(ids, ["A", "B"])
        let faces = await b.faces(for: "A")
        XCTAssertEqual(faces?.count, 2)
        XCTAssertEqual(faces?.first?.embedding, vec(3))
        XCTAssertEqual(faces?.first?.box, CGRect(x: 10, y: 20, width: 100, height: 120))
        let none = await b.faces(for: "B")
        XCTAssertEqual(none?.count, 0, "a scanned photo with no faces is still marked scanned")
        let missing = await b.faces(for: "Z")
        XCTAssertNil(missing)
    }

    func testRescanReplacesAndRemoveForgets() async {
        let s = FaceIndexStore(url: url)
        await s.record(assetId: "A", takenAt: nil, faces: [face("A", 1), face("A", 2)])
        await s.record(assetId: "A", takenAt: nil, faces: [face("A", 5)])
        let n1 = await s.faceCount
        XCTAssertEqual(n1, 1)
        await s.remove(assetIds: ["A"])
        let n2 = await s.faceCount
        let a2 = await s.assetCount
        XCTAssertEqual(n2, 0)
        XCTAssertEqual(a2, 0)
    }

    func testPendingIsNewestFirstAndResumes() {
        let lib: [(id: String, date: Date?)] = [("old", Date(timeIntervalSince1970: 1)), ("new", Date(timeIntervalSince1970: 9)),
                                                ("mid", Date(timeIntervalSince1970: 5)), ("nodate", nil)]
        XCTAssertEqual(FaceIndexer.pending(library: lib, indexed: []), ["new", "mid", "old", "nodate"])
        XCTAssertEqual(FaceIndexer.pending(library: lib, indexed: ["new", "mid"]), ["old", "nodate"])
    }

    func testSentLedger() async {
        let s = FaceIndexStore(url: url), f = UUID()
        await s.markSent(assetIds: ["A", "B"], to: f)
        let sent = await FaceIndexStore(url: url).sentAssetIds(to: f)
        XCTAssertEqual(sent, ["A", "B"])
    }

    func testEraseClearsEverything() async {
        let s = FaceIndexStore(url: url)
        await s.record(assetId: "A", takenAt: nil, faces: [face("A", 1)])
        await s.markSent(assetIds: ["A"], to: UUID())
        await s.erase()
        let c = await s.assetCount
        XCTAssertEqual(c, 0)
    }

    func testMatcherFindsFriendNewestFirstAndSkipsSent() {
        let friend = [vec(7), vec(7, jitter: 0.05)]
        let photos: [(assetId: String, takenAt: Date?, faces: [IndexedFace])] = [
            ("new", Date(timeIntervalSince1970: 30), [face("new", 7), face("new", 100)]),
            ("stranger", Date(timeIntervalSince1970: 20), [face("stranger", 100)]),
            ("sent", Date(timeIntervalSince1970: 10), [face("sent", 7)]),
            ("old", Date(timeIntervalSince1970: 5), [face("old", 7)]),
        ]
        let all = FaceIndexMatcher.matches(enrolled: friend, in: photos).map(\.assetId)
        XCTAssertEqual(all, ["new", "sent", "old"])
        XCTAssertEqual(FaceIndexMatcher.matches(enrolled: friend, in: photos, excluding: ["sent"]).map(\.assetId), ["new", "old"])
        XCTAssertTrue(FaceIndexMatcher.matches(enrolled: [], in: photos).isEmpty)
    }

    func testExistingFriendsAreSeededNotOffered() {
        let a = UUID(), b = UUID()
        var r = PastPhotosOffers.pendingFriends(current: [a], states: [:], seeded: false)
        XCTAssertEqual(r.seedAsDone, [a]); XCTAssertTrue(r.pending.isEmpty)
        r = PastPhotosOffers.pendingFriends(current: [a, b], states: [a: .done], seeded: true)
        XCTAssertEqual(r.pending, [b])
        r = PastPhotosOffers.pendingFriends(current: [a, b], states: [a: .done, b: .done], seeded: true)
        XCTAssertTrue(r.pending.isEmpty)
    }

    /// Real detector and embeddings over the committed fixtures: index "the camera roll" (bob, carol, dan photos), reopen
    /// the file as a relaunch would, and find bob from his two enrollment photos only.
    func testRealPhotosIndexedPersistedAndMatched() async throws {
        let base = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/faces")
        let detector = FaceDetector()
        func embed(_ file: String) throws -> [IndexedFace] {
            let img = try XCTUnwrap(UIImage(contentsOfFile: base.appendingPathComponent(file).path))
            let cg = try XCTUnwrap(img.preparedCGImage(maxDimension: 1024))
            return try detector.facesWithEmbeddings(in: cg).map {
                IndexedFace(assetId: file, takenAt: nil, embedding: $0.embedding, box: $0.box, imageSize: CGSize(width: cg.width, height: cg.height))
            }
        }
        let store = FaceIndexStore(url: url)
        let roll = ["bob_3.jpg", "bob_4.jpg", "bob_7_wide.jpg", "carol_3.jpg", "carol_4.jpg", "dan_3.jpg", "dan_4.jpg"]
        for (i, f) in roll.enumerated() {
            let faces = try embed(f).map { var x = $0; x.takenAt = Date(timeIntervalSince1970: Double(i)); return x }
            await store.record(assetId: f, takenAt: Date(timeIntervalSince1970: Double(i)), faces: faces)
        }
        let reopened = FaceIndexStore(url: url)       // relaunch: nothing rescanned
        let indexedCount = await reopened.assetCount
        XCTAssertEqual(indexedCount, roll.count)
        let bob = try ["bob_1.jpg", "bob_2.jpg"].compactMap { try embed($0).first?.embedding }
        let found = FaceIndexMatcher.matches(enrolled: bob, in: await reopened.facesByAsset()).map(\.assetId)
        print("[FaceIndexTest] bob matches in index: \(found)")
        // The Simulator's landmark detector is unusable (box-crop fallback), so recall here is partial; the point is that the
        // persisted index finds him at all and never finds anyone else. Recall is gated by `make facematch` on the Mac.
        XCTAssertTrue(found.contains("bob_3.jpg"))
        XCTAssertFalse(found.contains { $0.hasPrefix("carol") || $0.hasPrefix("dan") }, "no false matches")
    }
}

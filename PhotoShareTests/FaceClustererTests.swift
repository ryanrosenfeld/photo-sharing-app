import XCTest
@testable import PhotoShare

final class FaceClustererTests: XCTestCase {
    /// A unit-ish vector pointing mostly along `axis`, jittered a little so members of one person differ.
    private func vector(axis: Int, jitter: Float = 0, dims: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        v[axis] = 1
        v[(axis + 1) % dims] = jitter
        return v
    }

    private func face(_ asset: String, axis: Int, jitter: Float = 0, area: Float = 0.05, day: Int = 0) -> ScannedFace {
        ScannedFace(assetId: asset, takenAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                    vector: vector(axis: axis, jitter: jitter), areaFraction: area, crop: Data([UInt8(axis)]))
    }

    func testGroupsSamePersonAndRanksByDistinctPhotos() {
        var faces: [ScannedFace] = []
        for i in 0..<5 { faces.append(face("a\(i)", axis: 0, jitter: Float(i) * 0.05, day: i)) }   // person A: 5 photos
        for i in 0..<3 { faces.append(face("b\(i)", axis: 3, jitter: Float(i) * 0.05, day: i)) }   // person B: 3 photos
        let people = FaceClusterer().cluster(faces.shuffled())
        XCTAssertEqual(people.map(\.photoCount), [5, 3])
    }

    func testTwoFacesInOnePhotoCountOnce() {
        let faces = [face("p1", axis: 0), face("p1", axis: 0), face("p2", axis: 0), face("p3", axis: 0)]
        let people = FaceClusterer().cluster(faces)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].photoCount, 3)
    }

    func testDropsPeopleWhoAppearTooRarely() {
        let faces = [face("a", axis: 0), face("b", axis: 0), face("c", axis: 5)]
        XCTAssertTrue(FaceClusterer().cluster(faces).isEmpty)
    }

    func testDifferentPeopleStaySeparate() {
        var faces: [ScannedFace] = []
        for i in 0..<4 { faces.append(face("a\(i)", axis: 0)); faces.append(face("b\(i)", axis: 1)) }
        let people = FaceClusterer().cluster(faces)
        XCTAssertEqual(people.count, 2)
        XCTAssertTrue(people.allSatisfy { $0.photoCount == 4 })
    }

    func testTilePictureIsTheLargestFaceAndPhotosAreNewestFirst() {
        let faces = [face("old", axis: 2, area: 0.01, day: 1), face("big", axis: 2, area: 0.20, day: 2), face("new", axis: 2, area: 0.02, day: 3)]
        let p = FaceClusterer().cluster(faces)[0]
        XCTAssertEqual(p.assetIds, ["new", "big", "old"])
        XCTAssertEqual(p.crop, Data([2]))
    }

    func testInvitedPhotosStoreCapsAndPrunes() {
        let defaults = UserDefaults(suiteName: "invited-\(UUID().uuidString)")!
        InvitedPhotosStore.add(code: "c1", assetIds: (0..<80).map(String.init), now: Date(timeIntervalSince1970: 0), defaults: defaults)
        XCTAssertEqual(InvitedPhotosStore.all(defaults: defaults)[0].assetIds.count, InvitedPhotosStore.maxPhotos)
        InvitedPhotosStore.add(code: "c2", assetIds: ["x"], now: Date(), defaults: defaults)
        InvitedPhotosStore.prune(defaults: defaults)
        XCTAssertEqual(InvitedPhotosStore.all(defaults: defaults).map(\.code), ["c2"])
        InvitedPhotosStore.remove(code: "c2", defaults: defaults)
        XCTAssertTrue(InvitedPhotosStore.all(defaults: defaults).isEmpty)
    }

    func testCarryIdsKeepsIdWhenClusterGrows() {
        let old = [PersonCluster(id: UUID(), assetIds: ["a", "b", "c"], crop: nil)]
        let grown = [PersonCluster(id: UUID(), assetIds: ["a", "b", "c", "d"], crop: nil),
                     PersonCluster(id: UUID(), assetIds: ["x", "y", "z"], crop: nil)]
        let out = FaceClusterer.carryIds(into: grown, from: old)
        XCTAssertEqual(out[0].id, old[0].id)
        XCTAssertNotEqual(out[1].id, old[0].id)
    }

    func testKnownFacesAreNotSuggested() {
        var faces: [ScannedFace] = []
        for i in 0..<5 { faces.append(face("me\(i)", axis: 0, jitter: 0.02)) }
        for i in 0..<3 { faces.append(face("pal\(i)", axis: 3)) }
        let people = FaceClusterer().cluster(faces, excluding: [vector(axis: 0)])
        XCTAssertEqual(people.map(\.photoCount), [3])
    }
}

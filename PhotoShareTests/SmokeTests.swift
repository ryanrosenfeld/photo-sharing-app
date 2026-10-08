import XCTest
@testable import PhotoShare

final class SmokeTests: XCTestCase {
    func testHostAppBundleContainsFaceModel() {
        XCTAssertNotNil(
            Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc"),
            "MobileFaceNet.mlmodelc must be in the host app bundle"
        )
    }
}

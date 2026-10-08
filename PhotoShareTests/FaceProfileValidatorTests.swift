import UIKit
import XCTest
@testable import PhotoShare

/// The on-device quality gate for onboarding reference photos.
final class FaceProfileValidatorTests: XCTestCase {
    private func fixture(_ name: String) throws -> UIImage {
        let url = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/faces/\(name)")
        return try XCTUnwrap(UIImage(contentsOfFile: url.path))
    }

    func testPortraitIsAccepted() throws {
        XCTAssertEqual(FaceProfileValidator().validate(try fixture("alice_1.jpg")), .ok)
    }

    func testExifRotatedPortraitIsAccepted() throws {
        XCTAssertEqual(FaceProfileValidator().validate(try fixture("alice_5_exif_rotated.jpg")), .ok)
    }

    /// alice_6_large is a 4032x3024 camera frame with the face small in it: too small to enroll from.
    func testFaceSmallInLargeFrameIsRejected() throws {
        XCTAssertEqual(FaceProfileValidator().validate(try fixture("alice_6_large.jpg")), .faceTooSmall)
    }

    func testImageWithoutFaceIsRejected() {
        let size = CGSize(width: 800, height: 600)
        let blank = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        XCTAssertEqual(FaceProfileValidator().validate(blank), .noFace)
    }

    func testTinyFaceInLargeFrameIsRejected() throws {
        let face = try fixture("alice_1.jpg")
        let canvas = CGSize(width: 2400, height: 1800)
        let wide = UIGraphicsImageRenderer(size: canvas).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(origin: .zero, size: canvas))
            face.draw(in: CGRect(x: 1000, y: 700, width: 240, height: 240))
        }
        XCTAssertNotEqual(FaceProfileValidator().validate(wide), .ok)
    }
}

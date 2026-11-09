import XCTest
@testable import PhotoShare

/// Guided selfie instructions (SelfieGuidance.evaluate): when a frame is good enough to capture for each pose.
final class SelfieGuidanceTests: XCTestCase {
    private func face(width: CGFloat = 0.4, centered: Bool = true, yaw: Double? = 0, count: Int = 1) -> FaceReading {
        FaceReading(faceCount: count, width: width, centered: centered, yaw: yaw)
    }

    private func eval(_ r: FaceReading, _ pose: SelfiePose, first: Double? = nil) -> SelfieGuidance {
        SelfieGuidance.evaluate(r, pose: pose, firstTurnSign: first)
    }

    func testFramingComesFirst() {
        XCTAssertEqual(eval(FaceReading(faceCount: 0), .straight), .hint("bring your face into the circle"))
        XCTAssertEqual(eval(face(count: 2), .straight), .hint("just you in the frame"))
        XCTAssertEqual(eval(face(width: 0.1), .straight), .hint("move a little closer"))
        XCTAssertEqual(eval(face(width: 0.9), .straight), .hint("move back a little"))
        XCTAssertEqual(eval(face(centered: false), .straight), .hint("center your face in the circle"))
    }

    func testStraight() {
        XCTAssertEqual(eval(face(yaw: 0.05), .straight), .ready)
        XCTAssertEqual(eval(face(yaw: 0.5), .straight), .hint("look straight at the camera"))
        XCTAssertEqual(eval(face(yaw: nil), .straight), .ready, "no yaw reading: framing is enough")
    }

    func testFirstTurnEitherDirection() {
        XCTAssertEqual(eval(face(yaw: 0.1), .turn), .hint("turn your head a little to one side"))
        XCTAssertEqual(eval(face(yaw: 0.45), .turn), .ready)
        XCTAssertEqual(eval(face(yaw: -0.45), .turn), .ready, "mirroring can't make a turn wrong")
        XCTAssertEqual(eval(face(yaw: 1.5), .turn), .hint("not quite so far"))
    }

    func testSecondTurnMustGoTheOtherWay() {
        XCTAssertEqual(eval(face(yaw: 0.45), .turnOther, first: 1), .hint("now turn a little the other way"))
        XCTAssertEqual(eval(face(yaw: -0.45), .turnOther, first: 1), .ready)
        XCTAssertEqual(eval(face(yaw: 0.45), .turnOther, first: -1), .ready)
        XCTAssertEqual(eval(face(yaw: 0), .turnOther, first: 1), .hint("now turn a little the other way"))
    }

    /// Vision reports yaw in 45° steps on some revisions; a 45° turn must still count.
    func testQuantizedYawStillCounts() {
        XCTAssertEqual(eval(face(yaw: .pi / 4), .turn), .ready)
        XCTAssertEqual(eval(face(yaw: -.pi / 4), .turnOther, first: 1), .ready)
    }
}

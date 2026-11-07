import XCTest
@testable import PhotoShare

@MainActor
final class InviteTests: XCTestCase {
    private let code = "0123456789abcdef0123456789abcdef"
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "invite-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testPastedLinkMessageAndBareCode() {
        XCTAssertEqual(InviteLink.code(fromPasted: "photoshare://invite/\(code)"), code)
        XCTAssertEqual(InviteLink.code(fromPasted: "  \(code)\n"), code)
        XCTAssertEqual(InviteLink.code(fromPasted: code.uppercased()), code, "bare code is case-insensitive")
        let message = InviteMessage.text(from: "Dan") + " photoshare://invite/\(code)."
        XCTAssertEqual(InviteLink.code(fromPasted: message), code, "the whole share message works")
        XCTAssertEqual(InviteLink.code(fromPasted: "(photoshare://invite/\(code))"), code)
    }

    func testRejectsThingsThatAreNotInvites() {
        XCTAssertNil(InviteLink.code(fromPasted: ""))
        XCTAssertNil(InviteLink.code(fromPasted: "hello"))
        XCTAssertNil(InviteLink.code(fromPasted: "photoshare://invite/short"))
        XCTAssertNil(InviteLink.code(fromPasted: "photoshare://login-callback#access_token=abc"))
        XCTAssertNil(InviteLink.code(fromPasted: String(code.dropLast()) + "z"))
    }

    func testPendingInviteSurvivesRelaunchUntilCleared() {
        let router = InviteRouter(defaults: defaults)
        XCTAssertTrue(router.handle(URL(string: "photoshare://invite/\(code)")!))
        XCTAssertTrue(InviteRouter.hasStoredInvite(defaults))

        let relaunched = InviteRouter(defaults: defaults)
        XCTAssertEqual(relaunched.pendingCode, code, "killed during sign-up: the invite is still there")

        relaunched.pendingCode = nil   // accept screen dismissed
        XCTAssertNil(InviteRouter(defaults: defaults).pendingCode)
        XCTAssertFalse(InviteRouter.hasStoredInvite(defaults))
    }

    func testAuthCallbackIsNotAnInvite() {
        let router = InviteRouter(defaults: defaults)
        XCTAssertFalse(router.handle(URL(string: "photoshare://login-callback")!))
        XCTAssertNil(router.pendingCode)
    }

    func testSharedLinksAreNotOfferedAgain() {
        XCTAssertFalse(FriendsViewModel.wasShared(code, defaults: defaults))
        FriendsViewModel.markShared(code, defaults: defaults)
        FriendsViewModel.markShared(code, defaults: defaults)
        XCTAssertTrue(FriendsViewModel.wasShared(code, defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: "invite.sharedCodes")?.count, 1)
    }

    func testQRCodeRenders() {
        XCTAssertNotNil(InviteQRCode.render("photoshare://invite/\(code)"))
    }
}

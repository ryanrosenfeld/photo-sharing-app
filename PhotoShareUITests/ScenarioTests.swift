import XCTest

/// Atomic steps for the multi-persona scenario driven by scripts/verify/run_scenario.sh.
/// Each step is run separately (`-only-testing:PhotoShareUITests/ScenarioTests/<step>`) against a
/// specific simulator; persona + backend come from TEST_RUNNER_* env vars:
///   VERIFY_EMAIL, VERIFY_PASSWORD, VERIFY_SUPABASE_URL, VERIFY_SUPABASE_ANON_KEY, VERIFY_FRIEND (name).
final class ScenarioTests: XCTestCase {

    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app = XCUIApplication()
        app.launchEnvironment["PHOTOSHARE_SUPABASE_URL"] = env["VERIFY_SUPABASE_URL"] ?? ""
        app.launchEnvironment["PHOTOSHARE_SUPABASE_ANON_KEY"] = env["VERIFY_SUPABASE_ANON_KEY"] ?? ""
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The app awaits the Photos permission before loading anything, so answer the system alert explicitly
    /// (simctl privacy grants do not survive the test-runner reinstall).
    private func allowPhotosAccessIfAsked(timeout: TimeInterval = 6) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }
        for label in ["Allow Full Access", "Allow Access to All Photos"] where alert.buttons[label].exists {
            alert.buttons[label].tap(); return
        }
    }

    private func ensureSignedIn() {
        defer { allowPhotosAccessIfAsked() }
        if app.tabBars.buttons["Photos"].waitForExistence(timeout: 8) { return }
        let getStarted = app.buttons["welcome.signIn"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "welcome screen")
        getStarted.tap()
        app.buttons["auth.email"].tap()
        let email = app.textFields["emailAuth.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap(); email.typeText(env["VERIFY_EMAIL"] ?? "")
        let pw = app.secureTextFields["emailAuth.password"]
        pw.tap(); pw.typeText(env["VERIFY_PASSWORD"] ?? "")
        app.buttons["emailAuth.submit"].tap()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 20), "signed in -> main tabs")
    }

    /// Sign in; grant Photos access if the system alert appears (also pre-granted via simctl privacy).
    func testSignIn() {
        ensureSignedIn()
        shot("signed-in-photos-tab")
    }

    /// Alice: open Friends, enroll the friend from their face profile (no photo picker needed).
    func testEnrollFriendFromFaceProfile() {
        ensureSignedIn()
        app.tabBars.buttons["Friends"].tap()
        app.tap()  // lets the interruption monitor handle the Photos permission alert
        let enroll = app.buttons["friends.link.enroll"].firstMatch
        XCTAssertTrue(enroll.waitForExistence(timeout: 15), "outgoing friend row with enroll button")
        shot("friends-before-enroll")
        enroll.tap()
        let submit = app.buttons["enroll.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()
        let success = app.descendants(matching: .any)["enroll.success"]
        let done = success.waitForExistence(timeout: 60)
        shot(done ? "enrollment-complete" : "enrollment-timeout")
        XCTAssertTrue(done, "enrollment complete")
        app.buttons["enroll.done"].tap()
    }

    /// Bob: Photos tab shows `VERIFY_EXPECT_PHOTOS` received photo rows.
    func testPhotosTabShowsReceivedPhotos() {
        ensureSignedIn()
        app.tabBars.buttons["Photos"].tap()
        let expected = Int(env["VERIFY_EXPECT_PHOTOS"] ?? "1") ?? 1
        let row = app.descendants(matching: .any).matching(identifier: "photos.row")
        let deadline = Date().addingTimeInterval(20)
        while row.count < expected && Date() < deadline { usleep(500_000) }
        shot("photos-tab")
        XCTAssertEqual(row.count, expected, "received photo rows")
        XCTAssertTrue(app.staticTexts["Alice"].exists, "sender name on row")
    }

    /// Signed-in app sits in the foreground long enough for the auto-share pass to finish.
    func testSettleInForeground() {
        ensureSignedIn()
        sleep(UInt32(env["VERIFY_SETTLE_SECONDS"] ?? "20") ?? 20)
        shot("settled")
    }
}

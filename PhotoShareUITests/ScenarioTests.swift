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
        if app.buttons["tab.photos"].waitForExistence(timeout: 8) { return }
        let getStarted = app.buttons["welcome.signIn"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "welcome screen")
        getStarted.tap()
        let email = app.textFields["emailAuth.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap(); email.typeText(env["VERIFY_EMAIL"] ?? "")
        let pw = app.secureTextFields["emailAuth.password"]
        pw.tap(); pw.typeText(env["VERIFY_PASSWORD"] ?? "")
        app.buttons["emailAuth.submit"].tap()
        XCTAssertTrue(app.buttons["tab.photos"].waitForExistence(timeout: 20), "signed in -> main tabs")
    }

    /// Sign in; grant Photos access if the system alert appears (also pre-granted via simctl privacy).
    func testSignIn() {
        ensureSignedIn()
        shot("signed-in-photos-tab")
    }

    /// Alice: open Friends, enroll the friend from their face profile (no photo picker needed).
    func testEnrollFriendFromFaceProfile() {
        ensureSignedIn()
        app.buttons["tab.friends"].tap()
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

    // MARK: - Manual review mode

    /// Profile -> "Review before sending" set to `VERIFY_REVIEW` ("on"/"off").
    func testSetManualReview() {
        ensureSignedIn()
        app.buttons["tab.profile"].tap()
        let toggle = app.buttons["profile.manualReview"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "manual review toggle")
        let want = (env["VERIFY_REVIEW"] ?? "on") == "on"
        if (toggle.value as? String == "on") != want { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, want ? "on" : "off", "toggle state")
        shot("profile-manual-review-\(want ? "on" : "off")")
    }

    /// Friends tab -> review queue. Asserts `VERIFY_EXPECT_QUEUE` rows, then performs VERIFY_REVIEW_ACTION
    /// (`none`, `approve` or `reject`) on the first row, and checks the queue shrank by one.
    func testReviewQueue() {
        ensureSignedIn()
        app.buttons["tab.friends"].tap()
        let expected = Int(env["VERIFY_EXPECT_QUEUE"] ?? "1") ?? 1
        let entry = app.buttons["friends.reviewQueue"]
        if expected == 0 {
            sleep(2)
            XCTAssertFalse(entry.exists, "no review queue row when nothing is waiting")
            shot("friends-no-review-queue")
            return
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "Photos to Review row")
        shot("friends-with-review-badge")
        entry.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "review.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "review card")
        XCTAssertEqual(rows.count, expected, "queued photos")
        sleep(2)  // let thumbnails load
        shot("review-queue")
        let action = env["VERIFY_REVIEW_ACTION"] ?? "none"
        guard action != "none" else { return }
        app.buttons[action == "approve" ? "review.approve" : "review.reject"].firstMatch.tap()
        let deadline = Date().addingTimeInterval(40)
        while rows.count > expected - 1 && Date() < deadline { usleep(500_000) }
        XCTAssertEqual(rows.count, expected - 1, "queue after \(action)")
        if expected == 1 { XCTAssertTrue(app.descendants(matching: .any)["review.empty"].waitForExistence(timeout: 5)) }
        shot("review-after-\(action)")
    }

    /// Bob: Photos tab shows a polaroid stack from Alice (the stack groups photos by sender).
    func testPhotosTabShowsReceivedPhotos() {
        ensureSignedIn()
        app.buttons["tab.photos"].tap()
        let stack = app.descendants(matching: .any)["photos.stack.Alice"]
        let found = stack.waitForExistence(timeout: 30)
        shot("photos-tab")
        XCTAssertTrue(found, "photo stack from Alice on the Photos tab")
    }

    /// Signed-in app sits in the foreground long enough for the auto-share pass to finish.
    func testSettleInForeground() {
        ensureSignedIn()
        sleep(UInt32(env["VERIFY_SETTLE_SECONDS"] ?? "20") ?? 20)
        shot("settled")
    }
}

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
        // Already signed in but parked on the (skippable) notifications onboarding step.
        let pendingNotNow = app.buttons["notifications.skip"]
        if pendingNotNow.exists {
            pendingNotNow.tap()
            XCTAssertTrue(app.buttons["tab.photos"].waitForExistence(timeout: 30), "signed in -> main tabs")
            return
        }
        let getStarted = app.buttons["welcome.signIn"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "welcome screen")
        getStarted.tap()
        let email = app.textFields["emailAuth.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap(); email.typeText(env["VERIFY_EMAIL"] ?? "")
        let pw = app.secureTextFields["emailAuth.password"]
        pw.tap(); pw.typeText(env["VERIFY_PASSWORD"] ?? "")
        app.buttons["emailAuth.submit"].tap()
        // Existing personas already have a face profile; a fresh simulator still shows the notifications step.
        // Onboarding steps are derived from device state, so a fresh simulator can show photo access and/or
        // notifications before the tabs. Dismiss whatever appears until the tabs are there.
        let deadline = Date().addingTimeInterval(90)
        while !app.buttons["tab.photos"].exists && Date() < deadline {
            allowPhotosAccessIfAsked(timeout: 1)
            for id in ["notifications.skip", "photoAccess.continue", "photoAccess.skip"] where app.buttons[id].exists {
                app.buttons[id].tap()
            }
            usleep(500_000)
        }
        XCTAssertTrue(app.buttons["tab.photos"].exists, "signed in -> main tabs")
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
        let toggle = app.switches["profile.manualReview"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "manual review toggle")
        let want = (env["VERIFY_REVIEW"] ?? "on") == "on"
        if (toggle.value as? String == "1") != want { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, want ? "1" : "0", "toggle state")
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
        if expected == 1 { XCTAssertTrue(app.descendants(matching: .any)["review.empty"].waitForExistence(timeout: 8), "empty state") }
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

    // MARK: - Friends v3 (invite / accept / toggles / unfriend)

    private func openFriendsTab() {
        app.buttons["tab.friends"].tap()
        app.tap()  // lets the interruption monitor handle the Photos permission alert
    }

    /// The friend's row button (accessibility label is "<name>, <status>").
    private func friendRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "friends.row").matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
    }

    /// Inviter: open Add Friend, capture the generated link (written to VERIFY_OUT_FILE for the runner to compare with the DB).
    func testCreateInvite() {
        ensureSignedIn()
        openFriendsTab()
        let add = app.buttons["friends.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "add-friend button")
        add.tap()
        let link = app.staticTexts["invite.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), "invite link shown")
        if let path = env["VERIFY_OUT_FILE"] { try? link.label.write(toFile: path, atomically: true, encoding: .utf8) }
        shot("invite-sheet")
        XCTAssertTrue(link.label.hasPrefix("photoshare://invite/"), "link format: \(link.label)")
        XCTAssertTrue(app.buttons["invite.share"].exists, "share button")
    }

    /// Invitee: signed in and idle until the runner opens the deep link with `simctl openurl`
    /// (the runner polls VERIFY_READY_FILE). Handles iOS's "Open in PhotoShare?" prompt, accepts, checks the friend row.
    func testAcceptInviteViaDeepLink() {
        ensureSignedIn()
        if let path = env["VERIFY_READY_FILE"] { try? "ready".write(toFile: path, atomically: true, encoding: .utf8) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let title = app.staticTexts["invite.title"]
        let deadline = Date().addingTimeInterval(90)
        while !title.exists && Date() < deadline {
            let open = springboard.alerts.buttons["Open"]
            if open.exists { open.tap() }
            usleep(500_000)
        }
        XCTAssertTrue(title.exists, "accept screen after deep link")
        shot("invite-accept-screen")
        let who = env["VERIFY_EXPECT_NAME"] ?? ""
        XCTAssertTrue(title.label.contains(who), "accept screen names the inviter (\(who)): \(title.label)")
        app.buttons["invite.accept"].tap()
        XCTAssertTrue(app.staticTexts["invite.accepted"].waitForExistence(timeout: 15), "acceptance confirmation")
        shot("invite-accepted")
        app.buttons["invite.done"].tap()
        openFriendsTab()
        let found = friendRow(who).waitForExistence(timeout: 15)
        shot("friends-after-accept")
        XCTAssertTrue(found, "friend row for \(who)")
    }

    /// Opens the deep link when the invite is not usable (used/self/...) and checks the explanation.
    func testInviteLinkShowsProblem() {
        ensureSignedIn()
        if let path = env["VERIFY_READY_FILE"] { try? "ready".write(toFile: path, atomically: true, encoding: .utf8) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let problem = app.staticTexts["invite.problem"]
        let deadline = Date().addingTimeInterval(90)
        while !problem.exists && Date() < deadline {
            let open = springboard.alerts.buttons["Open"]
            if open.exists { open.tap() }
            usleep(500_000)
        }
        XCTAssertTrue(problem.exists, "problem message")
        shot("invite-problem")
        XCTAssertTrue(problem.label.contains(env["VERIFY_EXPECT_TEXT"] ?? ""), "problem text: \(problem.label)")
    }

    /// Friend detail: set a toggle. env: VERIFY_FRIEND (name), VERIFY_TOGGLE (send|receive), VERIFY_VALUE (on|off).
    func testSetFriendToggle() {
        ensureSignedIn()
        openFriendsTab()
        let name = env["VERIFY_FRIEND"] ?? ""
        let row = friendRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "friend row \(name)")
        row.tap()
        let toggle = app.switches["friend.\(env["VERIFY_TOGGLE"] ?? "send")"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "toggle")
        let want = (env["VERIFY_VALUE"] ?? "off") == "on" ? "1" : "0"
        shot("friend-detail-before")
        if (toggle.value as? String) != want { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }  // the switch sits at the row's trailing edge
        let settled = Date().addingTimeInterval(10)
        while (toggle.value as? String) != want && Date() < settled { usleep(300_000) }
        sleep(2)  // let the RPC + reload land
        shot("friend-detail-after")
        XCTAssertEqual(toggle.value as? String, want, "toggle value")
    }

    /// Friend detail -> "Review before sending" for VERIFY_FRIEND set to VERIFY_VALUE (on|off). The global setting is untouched.
    func testSetFriendReview() {
        ensureSignedIn()
        openFriendsTab()
        let row = friendRow(env["VERIFY_FRIEND"] ?? "")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "friend row")
        row.tap()
        let toggle = app.switches["friend.review"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "per-friend review toggle")
        let want = (env["VERIFY_VALUE"] ?? "on") == "on" ? "1" : "0"
        shot("friend-review-before")
        if (toggle.value as? String) != want { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        let settled = Date().addingTimeInterval(10)
        while (toggle.value as? String) != want && Date() < settled { usleep(300_000) }
        XCTAssertEqual(toggle.value as? String, want, "review toggle value")
        shot("friend-review-after")
        app.buttons["friend.done"].tap()
        // The Friends list shows a "Review" chip next to the name while review is on for this friend.
        let chip = app.staticTexts["friends.row.review"]
        if want == "1" {
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "Review chip on friend row")
        } else {
            sleep(1)
            XCTAssertFalse(chip.exists, "no Review chip when review is off")
        }
        shot("friends-row-review-chip-\(want)")
    }

    /// Friends list row status text. env: VERIFY_FRIEND, VERIFY_EXPECT_STATUS (substring).
    func testFriendRowStatus() {
        ensureSignedIn()
        openFriendsTab()
        let status = app.descendants(matching: .any).matching(identifier: "friends.row").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15), "friend row")
        shot("friends-row-status")
        XCTAssertTrue(status.label.contains(env["VERIFY_EXPECT_STATUS"] ?? ""), "status was: \(status.label)")
    }

    /// Detail -> Unfriend -> confirm; the list returns to the empty state.
    func testUnfriend() {
        ensureSignedIn()
        openFriendsTab()
        let row = friendRow(env["VERIFY_FRIEND"] ?? "")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "friend row")
        row.tap()
        app.buttons["friend.unfriend"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Unfriend' AND identifier != 'friend.unfriend'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation")
        shot("unfriend-confirm")
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["friends.empty"].waitForExistence(timeout: 10), "empty friends list")
        shot("friends-empty-after-unfriend")
    }
}

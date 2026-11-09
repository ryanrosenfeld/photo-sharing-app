import XCTest

/// New-account onboarding against local Supabase, driven by scripts/verify/run_onboarding.sh.
/// Expects 4 photos in the simulator library: 3 portraits and 1 landscape with no face.
/// Env: VERIFY_SUPABASE_URL, VERIFY_SUPABASE_ANON_KEY, VERIFY_NEW_EMAIL, VERIFY_PASSWORD.
final class OnboardingTests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PHOTOSHARE_SUPABASE_URL"] = env["VERIFY_SUPABASE_URL"] ?? ""
        app.launchEnvironment["PHOTOSHARE_SUPABASE_ANON_KEY"] = env["VERIFY_SUPABASE_ANON_KEY"] ?? ""
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func tapSystemAlert(_ labels: [String], timeout: TimeInterval = 10) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { XCTFail("no system alert"); return }
        for label in labels where alert.buttons[label].exists { alert.buttons[label].tap(); return }
        XCTFail("no matching button in alert: \(alert.buttons.allElementsBoundByIndex.map { $0.label })")
    }

    func testNewAccountOnboarding() {
        // --- Sign up ---
        let getStarted = app.buttons["welcome.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["welcome.haveInvite"].exists, "paste-an-invite entry on welcome")
        XCTAssertFalse(app.buttons["emailAuth.forgot"].exists)
        shot("01-welcome")
        getStarted.tap()
        signUpAndChooseFaces(name: "Erin Onboard", email: env["VERIFY_NEW_EMAIL"] ?? "", prefix: "0")

        // --- Photo access: explainer first, then the system prompt ---
        let photoContinue = app.buttons["photoAccess.continue"]
        XCTAssertTrue(photoContinue.waitForExistence(timeout: 30), "photo access explainer")
        shot("07-photo-explainer")
        photoContinue.tap()
        tapSystemAlert(["Allow Full Access", "Allow Access to All Photos"])

        // --- First friend: share a link, or show a QR code to someone in the room; skip is just as visible ---
        let share = app.buttons["firstFriend.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "first-friend step after photo access")
        XCTAssertTrue(app.buttons["firstFriend.skip"].exists, "skip is offered")
        shot("08-first-friend")
        app.buttons["firstFriend.qr"].tap()
        XCTAssertTrue(app.images["invite.qr"].waitForExistence(timeout: 5), "QR code for in-person invites")
        shot("08b-first-friend-qr")
        app.buttons["firstFriend.skip"].tap()

        // --- Notifications ---
        let allow = app.buttons["notifications.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "notifications explainer")
        shot("09-notifications-explainer")
        allow.tap()
        tapSystemAlert(["Allow"])

        // --- Home ---
        XCTAssertTrue(app.buttons["tab.photos"].waitForExistence(timeout: 20), "lands on main tabs")
        shot("10-home")

        // --- Friends: the link from onboarding is waiting; Add Friend reuses nothing already handed out ---
        app.buttons["tab.friends"].tap()
        let waiting = app.buttons["friends.invitesWaiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "the onboarding invite shows as waiting")
        XCTAssertTrue(app.buttons["friends.pasteInvite"].exists, "paste-an-invite entry on Friends")
        shot("11-friends-waiting")
        waiting.tap()
        XCTAssertTrue(app.images["invite.qr"].waitForExistence(timeout: 15), "Add Friend shows a QR code")
        XCTAssertTrue(app.buttons["invite.copy"].exists, "copy link")
        shot("12-add-friend")
        app.buttons["invite.copy"].tap()
        XCTAssertTrue(app.buttons["invite.another"].waitForExistence(timeout: 5), "after copying, offer a new link")
        app.buttons["invite.another"].tap()
        XCTAssertTrue(app.buttons["invite.cancel"].waitForExistence(timeout: 15), "earlier links listed with Cancel")
        shot("13-add-friend-links-waiting")
        let before = app.buttons.matching(identifier: "invite.cancel").count
        app.buttons["invite.cancel"].firstMatch.tap()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.buttons.matching(identifier: "invite.cancel").count >= before { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertLessThan(app.buttons.matching(identifier: "invite.cancel").count, before, "Cancel removes the link")
        shot("14-add-friend-cancelled")
        app.buttons["invite.done"].tap()
    }

    /// Someone opens a friend's invite before having an account: they see who invited them, the invite survives the
    /// app being killed mid sign-up, onboarding skips "invite a friend", and the accept screen follows onboarding.
    /// Env: VERIFY_INVITE_CODE (an invite from Dan), VERIFY_NEW_EMAIL2.
    func testInvitedNewAccount() {
        signOutIfNeeded()
        let code = env["VERIFY_INVITE_CODE"] ?? ""
        app.open(URL(string: "photoshare://invite/\(code)")!)
        let banner = app.descendants(matching: .any)["welcome.invitedBy"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "welcome names the inviter")
        XCTAssertTrue(banner.label.contains("Dan"), "banner: \(banner.label)")
        shot("20-welcome-invited")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["welcome.invitedBy"].waitForExistence(timeout: 15),
                      "the invite survives the app being killed")

        app.buttons["welcome.getStarted"].tap()
        signUpAndChooseFaces(name: "Finn Invited", email: env["VERIFY_NEW_EMAIL2"] ?? "", prefix: "2")

        // Photo access and notifications were already answered on this device; first-friend is skipped for invitees.
        let accept = app.buttons["invite.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 40), "accept screen right after onboarding")
        XCTAssertFalse(app.buttons["firstFriend.share"].exists)
        XCTAssertTrue(app.staticTexts["invite.title"].label.contains("Dan"))
        shot("26-accept")
        accept.tap()
        XCTAssertTrue(app.staticTexts["invite.accepted"].waitForExistence(timeout: 15), "accepted")
        shot("27-accepted")
        app.buttons["invite.done"].tap()
        app.buttons["tab.friends"].tap()
        XCTAssertTrue(app.staticTexts["Dan"].waitForExistence(timeout: 10), "Dan is in Friends")
        shot("28-friends")
    }

    /// Guided selfies: three poses captured automatically, then onboarding continues. The simulator has no camera,
    /// so the debug build reads stand-in frames from SELFIE_FIXTURES (VERIFY_SELFIE_FIXTURES, comma-separated paths).
    /// Env: VERIFY_NEW_EMAIL3.
    func testGuidedSelfies() {
        app.terminate()
        app.launchEnvironment["SELFIE_FIXTURES"] = env["VERIFY_SELFIE_FIXTURES"] ?? ""
        app.launch()
        signOutIfNeeded()
        app.buttons["welcome.getStarted"].tap()
        signUp(name: "Gia Selfie", email: env["VERIFY_NEW_EMAIL3"] ?? "", prefix: "4")

        let selfie = app.buttons["faceProfile.selfie"]
        XCTAssertTrue(selfie.waitForExistence(timeout: 20), "selfies are the main path when a camera is available")
        XCTAssertTrue(app.buttons["faceProfile.choose"].exists, "library stays as the fallback")
        XCTAssertFalse(app.buttons["faceProfile.continue"].isEnabled)
        shot("40-face-profile-selfie")
        selfie.tap()

        let instruction = app.staticTexts["selfie.instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 10), "guided capture opens")
        shot("41-selfie-straight")
        let progress = app.staticTexts["selfie.progress"]
        XCTAssertTrue(progress.label.hasPrefix("1 of 3"), progress.label)
        var sawTurn = false
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, instruction.exists {
            if !sawTurn, instruction.label.contains("turn") { sawTurn = true; shot("42-selfie-turn") }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(sawTurn, "asked to turn after the straight-on photo")
        XCTAssertFalse(instruction.exists, "capture closes after three photos")

        let ok = app.descendants(matching: .any).matching(identifier: "faceProfile.tile.ok")
        XCTAssertEqual(ok.count, 3, "three selfies accepted")
        XCTAssertTrue(app.buttons["faceProfile.choose"].label.contains("another day"), "optional variety from the library")
        shot("43-face-profile-selfies-taken")
        let cont = app.buttons["faceProfile.continue"]
        XCTAssertTrue(cont.isEnabled)
        cont.tap()
        // Permissions were answered and first-friend offered earlier on this device: straight to the app.
        XCTAssertTrue(app.buttons["tab.photos"].waitForExistence(timeout: 40), "onboarding finishes")
        shot("44-home")
    }

    /// The "Have an invite link?" path for a link that didn't open the app. Env: VERIFY_INVITE_CODE2 (from Carol).
    func testPasteInvite() {
        XCTAssertTrue(app.buttons["tab.friends"].waitForExistence(timeout: 20))
        app.buttons["tab.friends"].tap()
        app.buttons["friends.pasteInvite"].tap()
        let field = app.textFields["pasteInvite.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("not an invite")
        app.buttons["pasteInvite.open"].tap()
        XCTAssertTrue(app.staticTexts["pasteInvite.invalid"].waitForExistence(timeout: 5), "bad text explained")
        shot("30-paste-invalid")
        field.tap(); field.typeText(" Carol sent: photoshare://invite/\(env["VERIFY_INVITE_CODE2"] ?? "")")
        shot("31-paste-filled")
        app.buttons["pasteInvite.open"].tap()
        XCTAssertTrue(app.buttons["invite.accept"].waitForExistence(timeout: 15), "pasted link opens the accept screen")
        XCTAssertTrue(app.staticTexts["invite.title"].label.contains("Carol"))
        shot("32-paste-accept")
        app.buttons["invite.decline"].tap()
    }

    private func signOutIfNeeded() {
        let profile = app.buttons["tab.profile"]
        guard profile.waitForExistence(timeout: 10) else { return }
        profile.tap()
        let signOut = app.buttons["profile.signOut"]
        for _ in 0..<6 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        let confirm = app.sheets.buttons["Sign out"].firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        XCTAssertTrue(app.buttons["welcome.getStarted"].waitForExistence(timeout: 15), "signed out")
    }

    private func signUpAndChooseFaces(name nameText: String, email emailText: String, prefix: String) {
        signUp(name: nameText, email: emailText, prefix: prefix)
        chooseFacesFromLibrary(prefix: prefix)
    }

    private func signUp(name nameText: String, email emailText: String, prefix: String) {
        shot("\(prefix)2-signup-empty")
        let name = app.textFields["emailAuth.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Get Started opens in sign-up mode")
        name.tap(); name.typeText(nameText)
        let email = app.textFields["emailAuth.email"]
        email.tap(); email.typeText(emailText)
        // Reveal first: the iOS "Strong Password" sheet on a secure new-password field swallows simulated typing.
        app.buttons["emailAuth.showPassword"].tap()
        let pw = app.textFields["emailAuth.password"]
        pw.tap(); pw.typeText(env["VERIFY_PASSWORD"] ?? "")
        shot("\(prefix)3-signup-filled")
        app.buttons["emailAuth.submit"].tap()
    }

    private func chooseFacesFromLibrary(prefix: String) {
        // --- Face profile is required: cannot continue without photos ---
        let choose = app.buttons["faceProfile.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20), "signup lands on face profile step")
        let cont = app.buttons["faceProfile.continue"]
        XCTAssertFalse(cont.isEnabled, "Continue disabled with no photos")
        shot("\(prefix)4-face-profile-empty")

        // --- Pick all 4 library photos: 3 portraits pass, the landscape is rejected ---
        choose.tap()
        // The system picker is part of the app's accessibility tree; grid cells carry this identifier.
        let images = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 15), "photo picker")
        XCTAssertGreaterThanOrEqual(images.count, 4, "4 fixture photos visible in picker")
        // The cells report not-hittable (picker remote view), so tap their centres; skip duplicate frames.
        var seen = Set<String>(); var tapped = 0
        for i in 0..<images.count where tapped < 4 {
            let cell = images.element(boundBy: i)
            let key = "\(cell.frame)"
            if seen.contains(key) || cell.frame.height < 50 { continue }
            seen.insert(key); tapped += 1
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertEqual(tapped, 4, "tapped 4 distinct photos")
        shot("\(prefix)5-picker-selected")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isEnabled, "picker Done enabled")
        done.tap()

        let ok = app.descendants(matching: .any).matching(identifier: "faceProfile.tile.ok")
        let bad = app.descendants(matching: .any).matching(identifier: "faceProfile.tile.bad")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !(ok.count == 3 && bad.count == 1) { Thread.sleep(forTimeInterval: 0.5) }
        shot("\(prefix)6-face-profile-validated")
        XCTAssertEqual(ok.count, 3, "three portraits accepted")
        XCTAssertEqual(bad.count, 1, "the no-face photo is flagged")
        XCTAssertTrue(cont.isEnabled, "Continue enabled with 3 usable photos")
        cont.tap()
    }

    /// Relaunch after completing onboarding must go straight to the app (state is derived, nothing re-asked).
    func testRelaunchSkipsOnboarding() {
        XCTAssertTrue(app.buttons["tab.photos"].waitForExistence(timeout: 20), "straight to main tabs")
        shot("15-relaunch-home")
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.buttons["profile.photoStatus"].waitForExistence(timeout: 5), "live permissions rows on Profile")
        XCTAssertFalse(app.buttons["Turn off reference photos"].exists, "face profile cannot be turned off")
        shot("16-profile-permissions")
    }
}

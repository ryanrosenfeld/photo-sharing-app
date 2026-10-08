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
        shot("01-welcome")
        getStarted.tap()
        shot("02-signup-empty")
        let name = app.textFields["emailAuth.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Get Started opens in sign-up mode")
        name.tap(); name.typeText("Erin Onboard")
        let email = app.textFields["emailAuth.email"]
        email.tap(); email.typeText(env["VERIFY_NEW_EMAIL"] ?? "")
        // Reveal first: the iOS "Strong Password" sheet on a secure new-password field swallows simulated typing.
        app.buttons["emailAuth.showPassword"].tap()
        let pw = app.textFields["emailAuth.password"]
        pw.tap(); pw.typeText(env["VERIFY_PASSWORD"] ?? "")
        shot("03-signup-filled")
        app.buttons["emailAuth.submit"].tap()

        // --- Face profile is required: cannot continue without photos ---
        let choose = app.buttons["faceProfile.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20), "signup lands on face profile step")
        let cont = app.buttons["faceProfile.continue"]
        XCTAssertFalse(cont.isEnabled, "Continue disabled with no photos")
        shot("04-face-profile-empty")

        // --- Pick all 4 library photos: 3 portraits pass, the landscape is rejected ---
        choose.tap()
        let picker = app.otherElements["PHPickerViewController"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "photo picker")
        let images = picker.images
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(images.count, 4, "4 fixture photos visible in picker")
        for i in 0..<4 { images.element(boundBy: i).tap() }
        shot("05-picker-selected")
        picker.buttons["Add"].tap()

        let ok = app.descendants(matching: .any).matching(identifier: "faceProfile.tile.ok")
        let bad = app.descendants(matching: .any).matching(identifier: "faceProfile.tile.bad")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !(ok.count == 3 && bad.count == 1) { Thread.sleep(forTimeInterval: 0.5) }
        shot("06-face-profile-validated")
        XCTAssertEqual(ok.count, 3, "three portraits accepted")
        XCTAssertEqual(bad.count, 1, "the no-face photo is flagged")
        XCTAssertTrue(cont.isEnabled, "Continue enabled with 3 usable photos")
        cont.tap()

        // --- Photo access: explainer first, then the system prompt ---
        let photoContinue = app.buttons["photoAccess.continue"]
        XCTAssertTrue(photoContinue.waitForExistence(timeout: 30), "photo access explainer")
        shot("07-photo-explainer")
        photoContinue.tap()
        tapSystemAlert(["Allow Full Access", "Allow Access to All Photos"])

        // --- Notifications ---
        let allow = app.buttons["notifications.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "notifications explainer")
        shot("08-notifications-explainer")
        allow.tap()
        tapSystemAlert(["Allow"])

        // --- Home ---
        XCTAssertTrue(app.buttons["tab.photos"].waitForExistence(timeout: 20), "lands on main tabs")
        shot("09-home")
    }

    /// Relaunch after completing onboarding must go straight to the app (state is derived, nothing re-asked).
    func testRelaunchSkipsOnboarding() {
        XCTAssertTrue(app.buttons["tab.photos"].waitForExistence(timeout: 20), "straight to main tabs")
        shot("10-relaunch-home")
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.buttons["profile.photoStatus"].waitForExistence(timeout: 5), "live permissions rows on Profile")
        XCTAssertFalse(app.buttons["Turn off reference photos"].exists, "face profile cannot be turned off")
        shot("11-profile-permissions")
    }
}

import XCTest

final class LaunchSmokeTests: XCTestCase {
    func testSignedOutLaunchShowsWelcomeThenSignUpForm() {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["welcome.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15))
        getStarted.tap()

        // "Get started" opens the sign-up form: name, email, password.
        XCTAssertTrue(app.textFields["emailAuth.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["emailAuth.email"].exists)
        XCTAssertTrue(app.secureTextFields["emailAuth.password"].exists)
        XCTAssertTrue(app.buttons["emailAuth.submit"].exists)
    }
}

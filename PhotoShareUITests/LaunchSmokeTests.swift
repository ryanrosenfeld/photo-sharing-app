import XCTest

final class LaunchSmokeTests: XCTestCase {
    func testSignedOutLaunchShowsWelcomeThenEmailForm() {
        let app = XCUIApplication()
        app.launch()

        let getStarted = app.buttons["welcome.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15))
        getStarted.tap()

        XCTAssertTrue(app.textFields["emailAuth.email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["emailAuth.password"].exists)
        XCTAssertTrue(app.buttons["emailAuth.submit"].exists)
    }
}

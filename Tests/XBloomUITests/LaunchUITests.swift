import XCTest

@MainActor
final class LaunchUITests: XCTestCase {
    func testBrandRevealFinishesAndDoesNotReplayOnForeground() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        // XCTest may wait for the opening animation to settle before launch returns.
        XCTAssertTrue(app.buttons["Skip tour"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.otherElements["launch.brand"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["Skip tour"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["launch.brand"].exists)
    }
}

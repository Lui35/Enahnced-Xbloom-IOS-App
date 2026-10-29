import XCTest

@MainActor
final class LaunchUITests: XCTestCase {
    func testWaterWarningKeepsCardSizesAndExplainsRecovery() {
        let app = XCUIApplication()
        let arguments = ["-onboarding.completed.v1", "YES"]
        app.launchArguments = arguments
        app.launch()
        let choose = app.buttons["home.chooseRecipe"]
        let scale = app.buttons["home.tool.scale"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: choose)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(scale.exists)
        let originalScaleHeight = scale.frame.height
        let originalActionY = choose.frame.minY
        app.terminate()
        app.launchArguments = arguments + ["-previewLowWaterWarning"]
        app.launch()
        let warning = app.buttons["home.waterTankWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 15))
        let warningReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: warning)
        XCTAssertEqual(XCTWaiter.wait(for: [warningReady], timeout: 10), .completed)
        XCTAssertEqual(scale.frame.height, originalScaleHeight, accuracy: 1)
        XCTAssertEqual(choose.frame.minY, originalActionY, accuracy: 1)
        warning.tap()
        XCTAssertTrue(app.staticTexts["Check the water tank"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Refill the tank"].exists)
        XCTAssertTrue(app.staticTexts["Fit it firmly in place"].exists)
        app.buttons["waterTank.close"].tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertEqual(scale.frame.height, originalScaleHeight, accuracy: 1)
        XCTAssertEqual(choose.frame.minY, originalActionY, accuracy: 1)
    }

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

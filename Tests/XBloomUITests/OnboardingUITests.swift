import XCTest
import XBloomCore

@MainActor
final class OnboardingUITests: XCTestCase {
    func testRecipeLinkWaitsForGuestChoiceAndImportsIntoRecipes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-recipes.libraryLayout", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip tour"].waitForExistence(timeout: 10))
        var recipe = RecipeLibrary.defaults[0]
        recipe.name = "Shared cup \(UUID().uuidString.prefix(6))"
        app.open(try RecipeShareLink.make(for: recipe))
        XCTAssertTrue(app.staticTexts["Your coffee, your way."].exists)
        XCTAssertFalse(app.buttons["recipeLink.save"].exists)
        app.buttons["Skip tour"].tap()
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["recipeLink.save"].waitForExistence(timeout: 10))
        screenshot("07 Shared recipe preview", app: app)
        app.buttons["recipeLink.save"].tap()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Recipes"].isSelected)
        XCTAssertTrue(app.staticTexts[recipe.name].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "xbloom://recipe?data=invalid")))
        XCTAssertTrue(app.alerts["Couldn’t open recipe"].waitForExistence(timeout: 10))
    }

    func testTourGuestAccessAndCompletionSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your coffee, your way."].waitForExistence(timeout: 10))
        screenshot("01 Welcome", app: app)
        app.buttons["onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["Meet your machine."].exists)
        screenshot("02 Connect", app: app)
        app.buttons["onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["From bean to first sip."].exists)
        screenshot("03 Brew", app: app)
        app.buttons["onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["A little better, every brew."].exists)
        app.buttons["onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["Your studio awaits."].exists)
        screenshot("05 Account choice", app: app)
        XCTAssertTrue(app.buttons["onboarding.finish"].exists)
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Your coffee, your way."].exists)
    }

    func testSkipTourStillOffersAccountsAndGuestChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip tour"].waitForExistence(timeout: 10))
        app.buttons["Skip tour"].tap()
        XCTAssertTrue(app.staticTexts["Your studio awaits."].exists)
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Your coffee, your way."].exists)
        app.buttons["Skip tour"].tap()
        XCTAssertTrue(app.buttons["account.apple"].exists)
        XCTAssertTrue(app.textFields["account.email"].exists)
        app.buttons["account.mode.create"].tap()
        XCTAssertTrue(app.secureTextFields["account.confirmation"].exists)
        screenshot("06 Create account", app: app)
        app.swipeUp()
        app.buttons["account.benefits"].tap()
        XCTAssertTrue(app.staticTexts["Without an account"].exists)
        XCTAssertTrue(app.staticTexts["With an account"].exists)
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
    }

    func testEmailFormHasInlineErrorsAndCanRevealPassword() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip tour"].waitForExistence(timeout: 10))
        app.buttons["Skip tour"].tap()
        XCTAssertTrue(app.staticTexts["Your studio awaits."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["account.submit"].waitForExistence(timeout: 10))
        app.buttons["account.submit"].tap()
        XCTAssertTrue(app.staticTexts["Enter a valid email address."].exists)
        let address = app.textFields["account.email"]
        address.tap()
        address.typeText("coffee@example.com")
        let password = app.secureTextFields["account.password"]
        password.tap()
        password.typeText("sample-password")
        app.buttons["Show password"].tap()
        XCTAssertTrue(app.textFields["account.password"].exists)
        app.buttons["Hide password"].tap()
        XCTAssertTrue(app.secureTextFields["account.password"].exists)
        screenshot("08 Keyboard and password controls", app: app)
        // Never submit credentials to the backend in a UI design test.
    }

    func testLargeTextKeepsTourAndGuestActionsAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip tour"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["onboarding.continue"].isHittable)
        screenshot("09 Large text tour", app: app)
        app.buttons["Skip tour"].tap()
        XCTAssertTrue(app.buttons["onboarding.finish"].isHittable)
        screenshot("10 Large text account", app: app)
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

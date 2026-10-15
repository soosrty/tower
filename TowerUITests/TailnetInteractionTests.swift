import XCTest

@MainActor
final class TailnetInteractionTests: XCTestCase {
    func testAddingATailnetFromSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchArguments = ["-hasSeenWelcome", "YES", "--tab=export", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons.element(boundBy: 2).tap()
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        // The settings card's identifier is inherited by every row in it, so
        // the row is found by its title.
        let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tailscale 内网")).firstMatch
        for _ in 0..<8 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable)
        link.tap()

        let add = app.buttons["tailnet-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let save = app.buttons["tailnet-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))

        let subnet = app.textFields["tailnet-subnets"]
        XCTAssertTrue(subnet.waitForExistence(timeout: 5))
        subnet.tap()
        subnet.typeText("192.168.1.0")
        save.tap()
        // Missing prefix length: the sheet stays with an explanation.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "无法识别的子网")).firstMatch.waitForExistence(timeout: 5))

        subnet.tap()
        subnet.typeText("/24")
        save.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 个子网")).firstMatch.waitForExistence(timeout: 5))
    }
}

import XCTest

@MainActor
final class RulesPageLoadingInteractionTests: XCTestCase {
    func testVisibleStatisticsStayPresentWhenDelayedCloudSyncCompletes() {
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["TOWER_UI_TEST_SLOW_RULES"] = "1"
        app.launchEnvironment["TOWER_UI_TEST_RULES_SYNC"] = "1"
        app.launchArguments = ["-hasSeenWelcome", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["规则"].tap()
        let count = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "3,529 条")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        let groups = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "11 组")).firstMatch
        let deadline = Date.now.addingTimeInterval(6)
        while Date.now < deadline {
            guard count.exists, groups.exists else {
                XCTFail("Statistics disappeared after the rules page was already visible")
                return
            }
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "rules-statistics-after-delayed-cloud-sync"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFirstVisibleRulesCardAlreadyHasFinalStatistics() {
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["TOWER_UI_TEST_SLOW_RULES"] = "1"
        app.launchArguments = ["-hasSeenWelcome", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["规则"].tap()
        let card = app.buttons["编辑 ACL4SSR 默认"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let count = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "3,529 条")).firstMatch
        XCTAssertTrue(count.exists, "The first visible rules page must already have its real count")
        let placeholder = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "— 条")).firstMatch
        XCTAssertFalse(placeholder.exists, "Do not replace placeholders while the user is viewing statistics")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "rules-first-visible-final-statistics"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testColdRulesTabThenReentryAndEditing() {
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchArguments = ["-hasSeenWelcome", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["规则"].tap()
        let card = app.buttons["编辑 ACL4SSR 默认"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "rules-page-after-background-preparation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.tabBars.buttons["订阅"].tap()
        app.tabBars.buttons["规则"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["rule-actions-menu"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }
}

import XCTest

@MainActor
final class CloudRecoveryInteractionTests: XCTestCase {
    func testRecoveryListAppearsPromptly() {
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchArguments = ["-hasSeenWelcome", "YES", "--tab=export", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        let recovery = app.buttons["恢复同步备份"]
        for _ in 0..<8 where !recovery.isHittable { app.swipeUp() }
        recovery.tap()
        let copies = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "个节点"))
        XCTAssertTrue(copies.firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["暂无同步备份"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "当前使用")).firstMatch.exists)
        let initial = copies.allElementsBoundByIndex.map(\.label)
        for _ in 0..<5 {
            XCTAssertEqual(copies.allElementsBoundByIndex.map(\.label), initial)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "recovery-final-list"
        shot.lifetime = .keepAlways
        add(shot)
        app.navigationBars["恢复同步备份"].buttons["完成"].tap()
        XCTAssertTrue(recovery.waitForExistence(timeout: 3))
    }

    func testRecoveryPageRestoresConfigurationAndPreservesBackup() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["TOWER_UNIT_TEST_RUN"] = "1"
        app.launchArguments = ["-hasSeenWelcome", "YES", "--tab=export", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["open-settings"]
        let recovery = app.buttons["恢复同步备份"]
        let name = app.textFields["配置名称"]
        let copies = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "个节点"))
        func openSettings() {
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
        }
        func revealName() {
            for _ in 0..<8 where !name.isHittable { app.swipeUp() }
            XCTAssertTrue(name.isHittable)
        }
        func openRecovery() {
            for _ in 0..<8 where !recovery.isHittable { app.swipeUp() }
            XCTAssertTrue(recovery.isHittable)
            recovery.tap()
            // The copy combines its summary into a Button accessibility label.
            XCTAssertTrue(copies.firstMatch.waitForExistence(timeout: 10))
        }
        func restore(_ copy: XCUIElement) {
            copy.tap()
            let alert = app.alerts["恢复这份配置？"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.buttons["恢复"].tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: alert)
            waitForExpectations(timeout: 5)
        }
        openSettings()
        revealName()
        let originalName = name.value as? String ?? ""
        XCTAssertFalse(originalName.isEmpty)
        openRecovery()
        restore(copies.firstMatch)
        // Restoring the current state creates a backup, but equivalent rows
        // intentionally coalesce into one visible version.
        XCTAssertEqual(copies.count, 1)
        app.navigationBars["恢复同步备份"].buttons["完成"].tap()
        app.navigationBars["设置"].buttons["完成"].tap()

        openSettings()
        revealName()
        name.tap()
        name.typeText("-QA\n")
        XCTAssertNotEqual(name.value as? String, originalName)
        app.navigationBars["设置"].buttons["完成"].tap()
        openSettings()
        openRecovery()
        expectation(for: NSPredicate { _, _ in copies.count == 2 }, evaluatedWith: copies)
        waitForExpectations(timeout: 10)
        // Current edited state is first; the distinct original backup is next.
        restore(copies.element(boundBy: 1))
        expectation(for: NSPredicate { _, _ in copies.count == 2 }, evaluatedWith: copies)
        waitForExpectations(timeout: 10)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "isolated-cloud-recovery-distinct-versions"
        shot.lifetime = .keepAlways
        add(shot)
        app.navigationBars["恢复同步备份"].buttons["完成"].tap()
        app.navigationBars["设置"].buttons["完成"].tap()
        // Follow the normal dismissal flow and verify the restored value lasts.
        app.terminate()
        app.launch()
        openSettings()
        revealName()
        XCTAssertEqual(name.value as? String, originalName)
    }
}

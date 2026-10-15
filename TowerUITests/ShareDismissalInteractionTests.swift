import XCTest

@MainActor
final class ShareDismissalInteractionTests: XCTestCase {
    func testSubscriptionShareSwipeDismissal() { measureDismissal(node: false) }
    func testNodeShareSwipeDismissal() { measureDismissal(node: true) }

    func testLocalNodeShareSwipeDismissal() { measureDismissal(node: true, local: true) }

    func testSystemShareSwipeDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["TOWER_PERFORMANCE_NODE_COUNT"] = "1000"
        app.launchArguments = ["-hasSeenWelcome", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["add-source-button"].waitForExistence(timeout: 15))
        let share = app.buttons["分享 云帆机场"]
        for _ in 0..<8 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable)
        share.tap()
        XCTAssertTrue(app.buttons["分享链接"].waitForExistence(timeout: 5))
        app.buttons["分享链接"].tap()
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        // Drag the preview header, inside the system sheet's gesture surface.
        let start = activity.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: activity)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["分享链接"].isHittable)
        app.navigationBars["分享"].buttons["完成"].tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
    }

    private func measureDismissal(node: Bool, local: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["TOWER_PERFORMANCE_NODE_COUNT"] = "1000"
        app.launchArguments = ["-hasSeenWelcome", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["add-source-button"].waitForExistence(timeout: 15))
        let source = app.buttons["展开 云帆机场 的节点"]
        for _ in 0..<8 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable)
        if node && !local { source.tap() }
        let share = node
            ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH '分享 ' AND label CONTAINS %@", local ? "Perf 960" : "Perf 0")).firstMatch
            : app.buttons["分享 云帆机场"]
        for _ in 0..<30 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var metrics: [any XCTMetric] = [XCTCPUMetric(application: app)]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            share.tap()
            let done = app.navigationBars["分享"].buttons["完成"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            let qrShare = app.buttons["分享二维码"]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: qrShare)
            waitForExpectations(timeout: 10)
            let start = app.navigationBars["分享"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            startMeasuring()
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
            waitForExpectations(timeout: 5)
            stopMeasuring()
            XCTAssertTrue(share.isHittable)
        }
    }
}

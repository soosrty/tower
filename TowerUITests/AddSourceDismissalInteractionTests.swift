import XCTest
import UIKit

@MainActor
final class AddSourceDismissalInteractionTests: XCTestCase {
    func testSwipeDismissWithKeyboard() { measureDismissal(swipe: true, keyboard: true) }
    func testSwipeDismissWithoutKeyboard() { measureDismissal(swipe: true, keyboard: false) }
    func testCancelWithKeyboard() { measureDismissal(swipe: false, keyboard: true) }

    private func measureDismissal(swipe: Bool, keyboard: Bool) {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        UIPasteboard.general.string = ""
        #endif
        // A physical keyboard can change the clipboard between iterations.
        // Dismiss only this permission prompt; never import the user's clipboard.
        addUIInterruptionMonitor(withDescription: "Clipboard permission") { alert in
            let denyPaste = alert.buttons["不允许粘贴"]
            guard denyPaste.exists else { return false }
            denyPaste.tap()
            return true
        }
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["TOWER_PERFORMANCE_NODE_COUNT"] = "1000"
        app.launchArguments = ["-hasSeenWelcome", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["add-source-button"].waitForExistence(timeout: 15))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var metrics: [any XCTMetric] = [XCTCPUMetric(application: app)]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            app.buttons["add-source-button"].tap()
            let input = app.descendants(matching: .any)["source-value-field"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            let denyPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["不允许粘贴"]
            if denyPaste.waitForExistence(timeout: 0.5) { denyPaste.tap() }
            input.tap()
            if keyboard {
                // Some device keyboards omit the app's accessory toolbar and
                // live outside its accessibility tree. Still require input focus.
                expectation(for: NSPredicate { _, _ in
                    app.buttons["完成"].exists || app.keyboards.firstMatch.exists
                        || input.debugDescription.contains("Keyboard Focused")
                }, evaluatedWith: input)
                waitForExpectations(timeout: 5)
            } else {
                XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
                app.buttons["完成"].tap()
            }
            let bar = app.navigationBars["添加订阅或节点"]
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            startMeasuring()
            if swipe {
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            } else {
                app.navigationBars.buttons["取消"].tap()
            }
            XCTAssertTrue(app.buttons["add-source-button"].waitForExistence(timeout: 5))
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["save-source"])
            let dismissed = XCTWaiter.wait(for: [gone], timeout: 5) == .completed
            if !dismissed {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "sheet-did-not-dismiss"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            XCTAssertTrue(dismissed, "The sheet must finish dismissing")
            stopMeasuring()
        }
    }
}

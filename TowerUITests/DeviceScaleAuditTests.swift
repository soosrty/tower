import XCTest
import UIKit

/// Repeatable physical-device audit with disposable synthetic subscriptions.
@MainActor
final class DeviceScaleAuditTests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TOWER_UI_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["TOWER_PERFORMANCE_NODE_COUNT"] = "5000"
        app.launchArguments = ["-hasSeenWelcome", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["add-source-button"].waitForExistence(timeout: 30))
        print("SCALE_AUDIT nodes=5000 subscriptions=16 regions=30 maxFPS=\(UIScreen.main.maximumFramesPerSecond) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        return app
    }

    private func metrics(_ app: XCUIApplication) -> [any XCTMetric] {
        var result: [any XCTMetric] = [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        if #available(iOS 26.0, *) { result.append(XCTHitchMetric(application: app)) }
        return result
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test5000HomeAndExpandedSubscriptionScrolling() {
        let app = launch()
        defer { app.terminate() }
        let expand = app.buttons["展开 云帆机场 的节点"]
        for _ in 0..<6 where !expand.isHittable { app.swipeUp() }
        XCTAssertTrue(expand.isHittable)
        expand.tap()
        XCTAssertTrue(app.buttons["收起 云帆机场 的节点"].exists)
        capture(app, "5000-expanded-subscription")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: metrics(app) + [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<3 { app.swipeUp(); app.swipeDown() }
        }
        XCTAssertTrue(app.tabBars.buttons["订阅"].exists)
    }

    func test5000TabAndClientSwitching() {
        let app = launch()
        defer { app.terminate() }
        for title in ["规则", "导出", "订阅"] { app.tabBars.buttons[title].tap() }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: metrics(app), options: options) {
            app.tabBars.buttons["规则"].tap()
            app.tabBars.buttons["导出"].tap()
            for target in ["client-clash", "client-shadowrocket"] {
                let client = app.buttons[target]
                XCTAssertTrue(client.waitForExistence(timeout: 10))
                client.tap()
                let export = app.buttons["export-config"]
                expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export)
                waitForExpectations(timeout: 30)
            }
            app.tabBars.buttons["订阅"].tap()
        }
        capture(app, "5000-after-tab-and-client-switching")
    }

    func test5000SettingsSecurityAndPreview() {
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["导出"].tap()
        app.buttons["open-settings"].tap()
        let security = app.buttons["security-and-source-link"]
        for _ in 0..<10 where !security.isHittable { app.swipeUp() }
        XCTAssertTrue(security.isHittable)
        capture(app, "5000-settings-bottom")
        security.tap()
        XCTAssertTrue(app.navigationBars["安全与开源"].waitForExistence(timeout: 5))
        capture(app, "security-and-source")
        app.navigationBars["安全与开源"].buttons["设置"].tap()
        app.navigationBars["设置"].buttons["完成"].tap()
        let preview = app.buttons["preview-config"]
        let export = app.buttons["export-config"]
        for _ in 0..<8 {
            if preview.exists && preview.isHittable && preview.frame.maxY < export.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.buttons["preview-copy"].waitForExistence(timeout: 30))
        let readable = app.staticTexts["configuration-preview-text"]
        XCTAssertTrue(readable.waitForExistence(timeout: 5))
        let snapshotStart = ProcessInfo.processInfo.systemUptime
        let plainText = readable.label
        let snapshotSeconds = ProcessInfo.processInfo.systemUptime - snapshotStart
        print("PREVIEW_AX_SNAPSHOT seconds=\(snapshotSeconds) characters=\(plainText.count)")
        XCTAssertGreaterThan(plainText.count, 100_000, "The accessible configuration must not be truncated")
        XCTAssertTrue(plainText.contains("192.0.2.1"))
        XCTAssertLessThan(snapshotSeconds, 5, "Reading the preview must not block the main thread for tens of seconds")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: metrics(app), options: options) {
            app.swipeUp(); app.swipeUp(); app.swipeDown()
        }
        capture(app, "5000-configuration-preview")
    }

    func test5000SubscriptionEditorAndScannerSurface() {
        let app = launch()
        defer { app.terminate() }
        let source = app.buttons["展开 云帆机场 的节点"]
        for _ in 0..<6 where !source.isHittable { app.swipeUp() }
        source.press(forDuration: 0.7)
        app.buttons["编辑"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["编辑"].waitForExistence(timeout: 5))
        let address = app.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@", "https://example.invalid/performance/0")
        ).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        capture(app, "5000-subscription-editor")
        app.navigationBars["编辑"].buttons["取消"].tap()
        app.buttons["add-source-button"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyPaste = springboard.alerts.buttons["不允许粘贴"]
        if denyPaste.waitForExistence(timeout: 1) { denyPaste.tap() }
        app.buttons["扫码"].tap()
        // Opening the surface does not require granting a new camera permission.
        let denyCamera = springboard.alerts.buttons["不允许"]
        if denyCamera.waitForExistence(timeout: 1) { denyCamera.tap() }
        XCTAssertTrue(app.buttons["重新扫描"].waitForExistence(timeout: 5))
        app.buttons["重新扫描"].tap()
        app.buttons["手动添加"].tap()
        XCTAssertTrue(app.textFields["manual-server"].waitForExistence(timeout: 5))
        app.navigationBars["添加订阅或节点"].buttons["取消"].tap()
        XCTAssertTrue(app.buttons["add-source-button"].isHittable)
    }

    func test5000LANSharingSurfaceAndCancellation() {
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["导出"].tap()
        let first = app.buttons["client-shadowrocket"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let y = first.frame.midY
        let lan = app.buttons["client-lan-sharing"]
        for _ in 0..<12 {
            if lan.exists && lan.frame.minX >= 0 && lan.frame.maxX <= app.frame.width { break }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.width * 0.2, dy: y)))
        }
        XCTAssertTrue(lan.isHittable)
        lan.tap()
        // SwiftUI can propagate the enclosing card identifier to its controls.
        // The service may already be active after selecting the destination.
        let toggle = app.buttons["停止共享"]
        let start = app.buttons["开启局域网订阅"]
        expectation(for: NSPredicate { _, _ in toggle.exists || start.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        if start.exists { start.tap() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let rotate = app.buttons["更换访问密钥"]
        for _ in 0..<5 where !rotate.isHittable { app.swipeUp() }
        XCTAssertTrue(rotate.isHittable)
        rotate.tap()
        XCTAssertTrue(app.buttons["更换密钥并停用旧链接"].waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertTrue(app.buttons["开启局域网订阅"].waitForExistence(timeout: 5))
        capture(app, "5000-lan-sharing-surface")
    }
}

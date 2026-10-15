import Foundation

/// Unit-test host launches must never open the user's store or iCloud container.
/// UI tests already supply their own per-run fixture via TOWER_UI_TEST_RUN.
enum TowerTestIsolation {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["TOWER_UNIT_TEST_RUN"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tower-unit-" + UUID().uuidString)
    static var defaults: UserDefaults {
        isEnabled ? UserDefaults(suiteName: "tower-unit-" + String(ProcessInfo.processInfo.processIdentifier))! : .standard
    }
}

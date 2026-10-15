import XCTest
@testable import Tower

/// Rule schemes are rebuilt only when something they are built from changes.
@MainActor
final class RuleSchemeCacheTests: XCTestCase {
    func testUnrelatedSavesKeepMaterializedSchemes() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-rule-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = AppModel(persistence: PersistenceStore(fileURL: fileURL), arguments: [])
        let scheme = try XCTUnwrap(model.ruleSchemes.first { $0.isBundled && !$0.selectableRuleGroupNames.isEmpty })

        _ = model.customizableScheme(for: scheme)
        _ = model.effectiveScheme(scheme)
        let built = model.ruleSchemeMaterializationCount

        // Settings and node choices do not change what a scheme contains.
        model.setConfigurationName("Unrelated")
        _ = model.customizableScheme(for: scheme)
        _ = model.effectiveScheme(scheme)
        XCTAssertEqual(model.ruleSchemeMaterializationCount, built)

        // A rule-group choice does.
        let group = try XCTUnwrap(scheme.selectableRuleGroupNames.first {
            !scheme.protectedRuleGroupNames.contains($0)
        })
        model.setRuleGroup(group, enabled: false, for: scheme)
        _ = model.effectiveScheme(scheme)
        XCTAssertGreaterThan(model.ruleSchemeMaterializationCount, built)
    }
}

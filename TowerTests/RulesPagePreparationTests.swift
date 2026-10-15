import XCTest
@testable import Tower

@MainActor
final class RulesPagePreparationTests: XCTestCase {
    func testCloudSyncDoesNotClearPreparedStatisticsWhenRulesAreUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = CloudSyncPreference.isEnabled()
        CloudSyncPreference.setEnabled(false)
        defer { CloudSyncPreference.setEnabled(previous) }
        let cloud = CloudSyncStore(fileURL: directory.appendingPathComponent("cloud.json"))
        let model = AppModel(persistence: PersistenceStore(fileURL: directory.appendingPathComponent("local.json")),
                             cloudSync: cloud, arguments: [])
        await model.setICloudSyncEnabled(true)
        await model.prepareRulesPage()
        model.tabSelection = .rules
        let scheme = try XCTUnwrap(model.selectedScheme)
        let count = try XCTUnwrap(model.rulesPageSummaries[scheme.id]?.count)
        let groups = model.rulesPageSummaries[scheme.id]?.preview.groups
        let revision = model.ruleSchemePresentationRevision
        let materializations = model.ruleSchemeMaterializationCount

        // Simulate a foreground sync completing after the rules page is visible.
        await model.synchronizeWithCloud()
        XCTAssertNil(model.cloudSyncIssue)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.count, count)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.preview.groups, groups)
        XCTAssertEqual(model.ruleSchemePresentationRevision, revision)
        XCTAssertTrue(model.isRulesPagePrepared)

        // A remote edit to unrelated settings must not reset rules either.
        let downloaded = try await cloud.download()
        var remote = try XCTUnwrap(downloaded)
        remote.configurationName = "Renamed on another device"
        try await cloud.upload(remote)
        await model.synchronizeWithCloud()
        XCTAssertNil(model.cloudSyncIssue)
        XCTAssertEqual(model.configurationName, remote.configurationName)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.count, count)
        XCTAssertEqual(model.ruleSchemePresentationRevision, revision)
        await model.prepareRulesPage()
        XCTAssertEqual(model.ruleSchemeMaterializationCount, materializations)
        await model.setICloudSyncEnabled(false)
    }

    func testCloudRuleChangeKeepsDisplayUntilNewStatisticsArePrepared() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = CloudSyncPreference.isEnabled()
        CloudSyncPreference.setEnabled(false)
        defer { CloudSyncPreference.setEnabled(previous) }
        let cloud = CloudSyncStore(fileURL: directory.appendingPathComponent("cloud.json"))
        let model = AppModel(persistence: PersistenceStore(fileURL: directory.appendingPathComponent("local.json")),
                             cloudSync: cloud, arguments: [])
        await model.setICloudSyncEnabled(true)
        await model.prepareRulesPage()
        let scheme = try XCTUnwrap(model.selectedScheme)
        let count = try XCTUnwrap(model.rulesPageSummaries[scheme.id]?.count)
        let downloaded = try await cloud.download()
        var remote = try XCTUnwrap(downloaded)
        let group = try XCTUnwrap(scheme.selectableRuleGroupNames.first {
            !scheme.protectedRuleGroupNames.contains($0)
        })
        remote.selectedRuleGroups = [scheme.id: scheme.selectableRuleGroupNames.filter { $0 != group }]
        try await cloud.upload(remote)
        await model.synchronizeWithCloud()
        XCTAssertNil(model.cloudSyncIssue)
        XCTAssertFalse(model.isRulesPagePrepared)
        XCTAssertLessThan(model.ruleCount(for: scheme), count,
                          "Export must immediately use the changed rules, not the retained display")
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.count, count,
                       "Already visible statistics must not turn into placeholders during sync")
        await model.prepareRulesPage()
        XCTAssertLessThan(try XCTUnwrap(model.rulesPageSummaries[scheme.id]?.count), count)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.count, model.ruleCount(for: scheme))
        await model.setICloudSyncEnabled(false)
    }

    func testRulesNavigationWaitsForRealStatistics() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = AppModel(persistence: PersistenceStore(fileURL: fileURL), arguments: [])
        let initialMaterializations = model.ruleSchemeMaterializationCount
        model.tabSelection = .rules
        XCTAssertEqual(model.selectedTab, .subscriptions)
        await model.prepareRulesPage()
        let deadline = ContinuousClock.now + .seconds(2)
        while model.selectedTab != .rules && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.selectedTab, .rules)
        let scheme = try XCTUnwrap(model.selectedScheme)
        XCTAssertNotNil(model.rulesPageSummaries[scheme.id])
        XCTAssertTrue(model.isRulesPagePrepared)
        XCTAssertEqual(model.ruleSchemeMaterializationCount - initialMaterializations,
                       model.ruleSchemes.count * 2,
                       "Prewarming and navigation must share one preparation")
    }

    func testAnotherTabCancelsPendingRulesNavigation() async {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = AppModel(persistence: PersistenceStore(fileURL: fileURL), arguments: [])
        model.tabSelection = .rules
        model.tabSelection = .export
        XCTAssertEqual(model.selectedTab, .export)
        await model.prepareRulesPage()
        await Task.yield()
        XCTAssertEqual(model.selectedTab, .export, "Finishing background work must not pull the user back")
    }

    func testLargeRulesPageRenderingDoesNotParseListsOnMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-rules-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuleDownloadStore(folderURL: directory.appendingPathComponent("rules"))
        let url = URL(string: "https://example.com/large.list")!
        try store.store((0..<100_000).map { "DOMAIN-SUFFIX,domain\($0).example" }.joined(separator: "\n"), for: url)
        let model = AppModel(
            persistence: PersistenceStore(fileURL: directory.appendingPathComponent("state.json")),
            downloadStore: store,
            arguments: []
        )
        let scheme = RuleScheme(id: "large", name: "Large", summary: "", groups: [],
                                rulesets: [.init(groupName: "DIRECT", resource: .remote(url))])
        model.importedSchemes = [scheme]
        let initialMaterializations = model.ruleSchemeMaterializationCount
        XCTAssertNil(model.rulesPageSummaries[scheme.id])
        XCTAssertEqual(model.ruleSchemeMaterializationCount, initialMaterializations)
        let responsive = expectation(description: "Main actor runs while rule files are prepared")
        var preparationFinished = false
        DispatchQueue.main.async {
            XCTAssertFalse(preparationFinished, "Rule parsing must yield the main thread")
            responsive.fulfill()
        }
        await model.prepareRulesPage()
        preparationFinished = true
        await fulfillment(of: [responsive], timeout: 2)
        XCTAssertTrue(model.isRulesPagePrepared)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.count, 100_000)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.preview.rulesets, scheme.rulesets)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.isReady, true)
        let start = ContinuousClock.now
        XCTAssertEqual(model.customizableScheme(for: scheme).rulesets, scheme.rulesets)
        XCTAssertEqual(model.ruleCount(for: scheme), 100_000)
        XCTAssertTrue(model.isSchemeReady(scheme))
        let elapsed = start.duration(to: .now)
        print("Rules page main-actor rendering: \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(50), "Card rendering must use prepared data instead of parsing rule files")
    }

    func testCancelledPreparationDoesNotPublishAndCanBeRetried() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = AppModel(persistence: PersistenceStore(fileURL: fileURL), arguments: [])
        let task = Task { await model.prepareRulesPage() }
        task.cancel()
        await task.value
        XCTAssertFalse(model.isRulesPagePrepared)
        XCTAssertTrue(model.rulesPageSummaries.isEmpty)
        await model.prepareRulesPage()
        XCTAssertTrue(model.isRulesPagePrepared)
    }

    func testPreparationDiscardsAnOlderCustomizationAndPreservesRuleOrder() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = AppModel(persistence: PersistenceStore(fileURL: fileURL), arguments: [])
        let scheme = RuleScheme(id: "changing", name: "Changing", summary: "", groups: [], rulesets: [
            .init(groupName: "DIRECT", resource: .inline("DOMAIN-SUFFIX,example.com")),
            .init(groupName: "DIRECT", resource: .inline("FINAL"))
        ])
        model.importedSchemes = [scheme]
        var started = false
        let task = Task {
            started = true
            await model.prepareRulesPage()
        }
        while !started { await Task.yield() }
        model.upsertCustomRuleFlow(.init(schemeID: scheme.id, name: "Block", policyName: "REJECT",
                                        rulesText: "DOMAIN-SUFFIX,example.com"))
        await task.value
        XCTAssertFalse(model.isRulesPagePrepared)
        let expected = model.effectiveScheme(scheme)
        await model.prepareRulesPage()
        XCTAssertTrue(model.isRulesPagePrepared)
        XCTAssertEqual(model.effectiveScheme(scheme), expected)
        XCTAssertEqual(model.ruleCount(for: scheme), 3)
        XCTAssertEqual(model.effectiveScheme(scheme).rulesets.first?.groupName, "REJECT")
        let materializations = model.ruleSchemeMaterializationCount
        model.selectScheme(scheme)
        await model.prepareRulesPage()
        XCTAssertEqual(model.ruleSchemeMaterializationCount, materializations)
        XCTAssertTrue(model.isRulesPagePrepared)
    }

    func testChangingSelectedGroupsInvalidatesPreparedCounts() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = AppModel(persistence: PersistenceStore(fileURL: fileURL), arguments: [])
        let scheme = try XCTUnwrap(model.ruleSchemes.first { $0.isBundled })
        await model.prepareRulesPage()
        let group = try XCTUnwrap(scheme.selectableRuleGroupNames.first {
            !scheme.protectedRuleGroupNames.contains($0)
        })
        let originalCount = model.ruleCount(for: scheme)
        model.setRuleGroup(group, enabled: false, for: scheme)
        XCTAssertFalse(model.isRulesPagePrepared)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.count, originalCount,
                       "Keep display-only data until replacement is ready; do not remove the cards")
        await model.prepareRulesPage()
        let repository = RuleSchemeRepository()
        let expected = model.effectiveScheme(scheme).rulesets.reduce(0) {
            $0 + repository.lines(for: $1.resource).count
        }
        XCTAssertEqual(model.ruleCount(for: scheme), expected)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.count, expected)
        XCTAssertEqual(model.rulesPageSummaries[scheme.id]?.preview, model.customizableScheme(for: scheme))
        XCTAssertLessThan(expected, originalCount)
    }
}

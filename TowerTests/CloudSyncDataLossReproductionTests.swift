import XCTest
@testable import Tower

/// Empty devices must not publish destructive replacement snapshots.
@MainActor
final class CloudSyncDataLossReproductionTests: XCTestCase {
    func testRecoveryPublishesOnlyTheFinalListAfterCloudReturns() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = DelayedRecoveryStore()
        let model = AppModel(persistence: PersistenceStore(fileURL: folder.appendingPathComponent("local.json")), cloudSync: cloud, arguments: [])
        model.setConfigurationName("Local first")
        let load = Task { await model.loadCloudRecoveryCopies() }
        for _ in 0..<10_000 {
            if await cloud.isWaiting { break }
            await Task.yield()
        }
        let waiting = await cloud.isWaiting
        XCTAssertTrue(waiting)
        XCTAssertTrue(model.isLoadingCloudRecoveryCopies)
        XCTAssertTrue(model.cloudRecoveryCopies.isEmpty, "Do not expose a provisional version before cloud history is known")
        await cloud.finish()
        await load.value
        XCTAssertFalse(model.isLoadingCloudRecoveryCopies)
        XCTAssertEqual(model.cloudRecoveryCopies.first?.snapshot.configurationName, "Local first")
    }

    func testUntouchedEmptyMacDownloadsPopulatedPhoneSnapshot() async throws {
        try await runEmptyMacScenario(editBeforeEnabling: false)
    }

    func testEmptyMacSettingsEditCannotClearCloudOrPhone() async throws {
        try await runEmptyMacScenario(editBeforeEnabling: true)
    }

    func testCurrentLocalVersionCanBeChosenBeforeAnyBackupExists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(persistence: PersistenceStore(fileURL: folder.appendingPathComponent("local.json")), cloudSync: CloudSyncStore(fileURL: folder.appendingPathComponent("cloud.json")), arguments: [])
        model.setConfigurationName("Keep this device")
        await model.loadCloudRecoveryCopies()
        let current = try XCTUnwrap(model.cloudRecoveryCopies.first { $0.id == "current-local" })
        XCTAssertEqual(current.snapshot.configurationName, "Keep this device")
        await model.restoreCloudCopy(current)
        XCTAssertNil(model.cloudSyncIssue)
        await model.loadCloudRecoveryCopies()
        XCTAssertEqual(model.cloudRecoveryCopies.count, 1)
    }

    func testForegroundChecksOnceUntilBackgroundAndManualSyncStillWorks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = CloudSyncPreference.isEnabled()
        CloudSyncPreference.setEnabled(false)
        defer { CloudSyncPreference.setEnabled(previous) }
        let cloud = CloudSyncStore(fileURL: folder.appendingPathComponent("cloud.json"))
        let store = PersistenceStore(fileURL: folder.appendingPathComponent("local.json"))
        // Checks every return here; the default throttles to once per 10 min.
        let model = AppModel(persistence: store, cloudSync: cloud, cloudForegroundCheckInterval: 0, arguments: [])
        await model.setICloudSyncEnabled(true)
        await model.performForegroundOpenWork()
        let downloaded = try await cloud.download()
        var remote = try XCTUnwrap(downloaded)
        remote.configurationName = "Changed on Mac"
        try await cloud.upload(remote)
        await model.performForegroundOpenWork()
        XCTAssertNotEqual(model.configurationName, "Changed on Mac")
        model.didEnterBackground()
        await model.performForegroundOpenWork()
        XCTAssertEqual(model.configurationName, "Changed on Mac")
        remote.configurationName = "Manual update"
        try await cloud.upload(remote)
        await model.synchronizeWithCloud(showResult: true)
        XCTAssertEqual(model.configurationName, "Manual update")
        await model.loadCloudRecoveryCopies()
        let copies = model.cloudRecoveryCopies
        for (index, copy) in copies.enumerated() {
            XCTAssertFalse(copies.dropFirst(index + 1).contains { CloudSnapshotMerge.equal(copy.snapshot, $0.snapshot) })
        }
        await model.setICloudSyncEnabled(false)
    }

    /// After a sync, merely using the app (viewing another client, a refresh,
    /// resolved countries) must not look like an unsynced change.
    func testSyncedStateIsNotReportedAsChangedWithoutAnEdit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = CloudSyncPreference.isEnabled()
        CloudSyncPreference.setEnabled(false)
        defer { CloudSyncPreference.setEnabled(previous) }
        let model = AppModel(persistence: PersistenceStore(fileURL: folder.appendingPathComponent("local.json")),
                             cloudSync: CloudSyncStore(fileURL: folder.appendingPathComponent("cloud.json")), arguments: [])
        model.setConfigurationName("Phone")
        await model.setICloudSyncEnabled(true)
        XCTAssertNotNil(model.lastCloudSyncAt)
        let unsyncedRightAfterSync = await model.hasUnsyncedCloudChanges()
        XCTAssertFalse(unsyncedRightAfterSync)
        model.selectedTarget = .clash
        let unsyncedAfterBrowsing = await model.hasUnsyncedCloudChanges()
        XCTAssertFalse(unsyncedAfterBrowsing)
        model.setConfigurationName("Renamed")
        let unsyncedAfterEdit = await model.hasUnsyncedCloudChanges()
        XCTAssertTrue(unsyncedAfterEdit)
        await model.setICloudSyncEnabled(false)
    }

    func testRestoringUndatedSnapshotCreatesBackup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersistenceStore(fileURL: folder.appendingPathComponent("local.json"))
        try store.save(AppSnapshot(subscriptions: [], nodes: [], selectedPresetID: "default", selectedTarget: .surge))
        let model = AppModel(persistence: store, cloudSync: CloudSyncStore(fileURL: folder.appendingPathComponent("cloud.json")), arguments: [])
        await model.loadCloudRecoveryCopies()
        let current = try XCTUnwrap(model.cloudRecoveryCopies.first)
        await model.restoreCloudCopy(current)
        XCTAssertNil(model.cloudSyncIssue)
        XCTAssertEqual(try store.recoveryCopies().count, 1)
    }

    private func runEmptyMacScenario(editBeforeEnabling: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = CloudSyncPreference.isEnabled()
        CloudSyncPreference.setEnabled(false)
        defer { CloudSyncPreference.setEnabled(previous) }
        let cloud = CloudSyncStore(fileURL: folder.appendingPathComponent("cloud.json"))
        let phoneStore = PersistenceStore(fileURL: folder.appendingPathComponent("phone.json"))
        let scheme = try RuleSchemeParser().parse(text: """
        [Proxy Group]
        Main = select, DIRECT
        [Rule]
        DOMAIN,example.com,Main
        FINAL,Main
        """, id: "owned-rules", name: "Owned Rules", summary: "Fixture")
        let populated = AppSnapshot(
            subscriptions: [SubscriptionSource(name: "Fixture", urlString: "https://example.invalid/sub")],
            nodes: [ProxyNode(kind: .trojan, name: "Fixture", server: "example.invalid", port: 443, password: "fixture", rawURI: "")],
            selectedPresetID: scheme.id, selectedTarget: .surge,
            importedSchemes: [scheme], updatedAt: Date.now.addingTimeInterval(-3600)
        )
        try phoneStore.save(populated)
        try await cloud.upload(populated)
        let phone = AppModel(persistence: phoneStore, cloudSync: cloud, arguments: [], clientPlatform: .phone)
        let mac = AppModel(persistence: PersistenceStore(fileURL: folder.appendingPathComponent("mac.json")), cloudSync: cloud, arguments: [], clientPlatform: .mac)
        XCTAssertEqual(phone.nodes.count, 1)
        XCTAssertEqual(phone.importedSchemes.first?.groups.count, 1)
        XCTAssertEqual(phone.importedSchemes.first?.rulesets.count, 2)
        XCTAssertTrue(mac.nodes.isEmpty)
        if editBeforeEnabling { mac.setConfigurationName("My Mac") }
        await mac.setICloudSyncEnabled(true)
        let remote = try await cloud.download()
        XCTAssertEqual(remote?.nodes.count, 1)
        await phone.setICloudSyncEnabled(true)
        XCTAssertEqual(phone.nodes.count, 1)
        XCTAssertEqual(phone.subscriptions.count, 1)
        XCTAssertEqual(phone.importedSchemes.count, 1)
        XCTAssertEqual(try phoneStore.load()?.nodes.count, 1)
        await phone.setICloudSyncEnabled(false)
        await mac.setICloudSyncEnabled(false)
    }
}

private actor DelayedRecoveryStore: CloudSnapshotSyncing {
    nonisolated let isAccountAvailable = false
    private var continuation: CheckedContinuation<[CloudRecoveryCopy], Never>?
    var isWaiting: Bool { continuation != nil }
    func recoveryCopies() async throws -> [CloudRecoveryCopy] {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: []); continuation = nil }
    func download() async throws -> AppSnapshot? { nil }
    func upload(_ snapshot: AppSnapshot) async throws {}
    func removeRemoteSnapshot() async throws {}
    func commit(_ snapshot: AppSnapshot, replacing expected: AppSnapshot?) async throws {}
}

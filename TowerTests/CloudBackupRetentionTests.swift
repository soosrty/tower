import XCTest
@testable import Tower

final class CloudBackupRetentionTests: XCTestCase {
    private func snapshot(_ index: Int) -> AppSnapshot {
        AppSnapshot(subscriptions: [], nodes: [], selectedPresetID: "default", selectedTarget: .surge,
                    configurationName: "Version \(index)", updatedAt: Date(timeIntervalSince1970: Double(index)))
    }
    func testRepeatedContentDoesNotConsumeBackupSlots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PersistenceStore(fileURL: dir.appendingPathComponent("state.json"))
        for i in 0..<14 {
            var copy = snapshot(0)
            copy.updatedAt = Date(timeIntervalSince1970: Double(i))
            try store.backup(copy)
        }
        XCTAssertEqual(try store.recoveryCopies().count, 1)
    }
    func testExistingDuplicateBackupsAreCleanedBeforeApplyingLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = dir.appendingPathComponent("state.json-backups")
        for i in 0..<14 {
            var copy = snapshot(i % 2)
            copy.updatedAt = Date(timeIntervalSince1970: Double(i))
            try PersistenceStore(fileURL: backups.appendingPathComponent("\(i).json")).save(copy)
        }
        let store = PersistenceStore(fileURL: dir.appendingPathComponent("state.json"))
        XCTAssertEqual(try store.recoveryCopies().count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 2)
    }

    func testLocalBackupsKeepNewestFive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PersistenceStore(fileURL: dir.appendingPathComponent("state.json"))
        for i in 0..<14 { try store.backup(snapshot(i)) }
        let copies = try store.recoveryCopies()
        XCTAssertEqual(copies.count, CloudSnapshotJournal.retentionLimit)
        XCTAssertEqual(Set(copies.map { $0.snapshot.configurationName }), Set((9..<14).map { "Version \($0)" }))
        // New backups are stored compressed.
        let files = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("state.json-backups").path)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".json.lzfse") })
    }
    func testCloudKeepsFiveSnapshotsAndStillReadsLatest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CloudSyncStore(fileURL: dir.appendingPathComponent("state.json"))
        for i in 0..<14 { try await store.upload(snapshot(i)) }
        let copies = try await store.recoveryCopies()
        XCTAssertEqual(copies.count, CloudSnapshotJournal.retentionLimit)
        XCTAssertEqual(Set(copies.map { $0.snapshot.configurationName }), Set((9..<14).map { "Version \($0)" }))
        let current = try await store.download()
        XCTAssertEqual(current?.configurationName, "Version 13")
        let files = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("state-versions-v2"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, CloudSnapshotJournal.retentionLimit)
    }
    func testDelayedBranchWithPrunedBaseFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = CloudSnapshotJournal(directory: dir)
        try journal.append(snapshot(0), parents: [])
        let oldParents = journal.heads(try journal.commits())
        let original = try Data(contentsOf: dir.appendingPathComponent(oldParents[0] + ".json"))
        for i in 1..<14 {
            try journal.append(snapshot(i), parents: journal.heads(try journal.commits()))
            try journal.prune()
        }
        // iCloud can redeliver a full file after its cleanup marker.
        try original.write(to: dir.appendingPathComponent(oldParents[0] + ".json"))
        XCTAssertNil(try journal.commits()[oldParents[0]]?.snapshot)
        try journal.append(snapshot(99), parents: oldParents)
        try journal.prune()
        XCTAssertThrowsError(try journal.snapshot(journal.commits())) { error in
            XCTAssertEqual(error as? CloudSyncError, .conflict)
        }
        XCTAssertEqual(try journal.commits().values.filter { $0.snapshot != nil }.count, CloudSnapshotJournal.retentionLimit)
    }
    func testRecentConcurrentBranchesCanStillMergeAfterPruning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = CloudSnapshotJournal(directory: dir)
        for i in 0..<14 {
            try journal.append(snapshot(i), parents: journal.heads(try journal.commits()))
            try journal.prune()
        }
        let parents = journal.heads(try journal.commits())
        var left = snapshot(13); left.configurationName = "Left"
        var right = snapshot(13); right.selectedTarget = .clash
        try journal.append(left, parents: parents)
        try journal.append(right, parents: parents)
        try journal.prune()
        let current = try journal.snapshot(journal.commits())
        XCTAssertEqual(current?.configurationName, "Left")
        XCTAssertEqual(current?.selectedTarget, .clash)
    }

}

import Foundation
import Testing
@testable import Tower

/// What counts as a change worth an iCloud sync, a backup and a history slot.
struct CloudSyncSignatureTests {
    private let source = SubscriptionSource(name: "Airport", urlString: "https://example.com/sub")

    private func node(_ name: String, server: String, id: UUID = UUID(), sourced: Bool = true) -> ProxyNode {
        ProxyNode(id: id, sourceID: sourced ? source.id : nil, kind: .shadowsocks, name: name,
                  server: server, port: 443, cipher: "aes-128-gcm", password: "test", rawURI: "ss://\(server)")
    }

    private func snapshot(nodes: [ProxyNode], excluded: [UUID] = []) -> AppSnapshot {
        AppSnapshot(subscriptions: [source], nodes: nodes, selectedPresetID: AppModel.defaultRuleSchemeID,
                    selectedTarget: .surge, excludedNodeIDs: excluded.isEmpty ? nil : excluded)
    }

    @Test func refreshStatusCachesAndFreshNodeIDsAreNotAChange() {
        let before = [node("HK 01", server: "hk.example"), node("JP 01", server: "jp.example")]
        let original = snapshot(nodes: before, excluded: [before[1].id])

        // A refresh: new ids, the exclusion carried over to the same node,
        // status rewritten, caches filled, a different client being viewed.
        var refreshed = snapshot(nodes: before.map { node($0.name + " | 剩余 12G", server: $0.server) })
        refreshed.excludedNodeIDs = [refreshed.nodes[1].id]
        refreshed.subscriptions[0].lastUpdatedAt = .now
        refreshed.subscriptions[0].lastError = "timeout"
        refreshed.subscriptions[0].usage = SubscriptionUsage(uploadBytes: 1, downloadBytes: 2, totalBytes: 3)
        refreshed.resolvedHostCountryCodes = ["hk.example": "HK"]
        refreshed.resolvedHostCountryCodeUpdatedAt = ["hk.example": .now]
        refreshed.selectedTarget = .clash
        refreshed.updatedAt = .now

        #expect(CloudSnapshotMerge.sameContent(original, refreshed))
    }

    @Test func userDecisionsAreChanges() {
        let nodes = [node("HK 01", server: "hk.example"), node("JP 01", server: "jp.example")]
        let original = snapshot(nodes: nodes)

        var renamed = original
        renamed.subscriptions[0].name = "Renamed"
        #expect(!CloudSnapshotMerge.sameContent(original, renamed))

        // Excluding a fetched node is the user's choice.
        #expect(!CloudSnapshotMerge.sameContent(original, snapshot(nodes: nodes, excluded: [nodes[0].id])))

        var overridden = original
        overridden.nodes[0].countryOverride = "SG"
        #expect(!CloudSnapshotMerge.sameContent(original, overridden))

        var withLocalNode = original
        withLocalNode.nodes.append(node("Home", server: "home.example", sourced: false))
        #expect(!CloudSnapshotMerge.sameContent(original, withLocalNode))

        var setting = original
        setting.configurationName = "Mine"
        #expect(!CloudSnapshotMerge.sameContent(original, setting))
    }

    @Test func refreshingARuleSchemeIsNotAChange() {
        let scheme = RuleScheme(id: "imported", name: "Imported", summary: "", groups: [], rulesets: [],
                                updatedAt: .distantPast, isBundled: false)
        var original = snapshot(nodes: [])
        original.importedSchemes = [scheme]
        var refreshed = original
        refreshed.importedSchemes?[0].updatedAt = .now
        #expect(CloudSnapshotMerge.sameContent(original, refreshed))

        var renamed = original
        renamed.importedSchemes?[0].name = "Renamed"
        #expect(!CloudSnapshotMerge.sameContent(original, renamed))
    }

    @Test func recoveryCopiesDifferingOnlyInStatusCollapse() {
        var status = snapshot(nodes: [node("HK 01", server: "hk.example")])
        let first = CloudRecoveryCopy(id: "a", snapshot: status)
        status.subscriptions[0].lastUpdatedAt = .now
        status.nodes = [node("HK 01", server: "hk.example")]
        let second = CloudRecoveryCopy(id: "b", snapshot: status)
        #expect(CloudRecoveryCopy.unique([first, second]).map(\.id) == ["a"])
    }

    @Test func aResolvedHostMissingFromTheDatabaseIsNotRetriedSoon() async {
        // 1.1.1.1 resolves but has no entry: a settled answer, cached as long
        // as a success; only a DNS failure uses the short failure window.
        let data = Data([8,8,8,0,8,8,8,255] + Array("US".utf8))
        let counter = ResolveCounter()
        let service = IPCountryLookupService(
            database: IPCountryDatabase(ipv4Data: data, ipv6Data: Data()),
            failureTTL: 0,
            resolver: { _ in
                await counter.increment()
                return ["1.1.1.1"]
            }
        )
        #expect(await service.countryCode(forHost: "unknown.example") == nil)
        #expect(await service.countryCode(forHost: "unknown.example") == nil)
        #expect(await counter.count == 1)
    }
}

struct CloudJournalCacheTests {
    @Test func cachedRecordsFollowNewMarkersAndDeletions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = CloudSnapshotJournal(directory: folder)
        let snapshot = AppSnapshot(subscriptions: [], nodes: [], selectedPresetID: AppModel.defaultRuleSchemeID, selectedTarget: .surge)
        try journal.append(snapshot, parents: [])
        let first = try journal.commits()
        let id = try #require(first.keys.first)
        #expect(first[id]?.snapshot != nil)

        // A pruning marker written after the record was cached still wins.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let marker = CloudSnapshotJournal.Commit(id: id, parents: [], snapshot: nil)
        try encoder.encode(marker).write(to: folder.appendingPathComponent(id + ".pruned"))
        #expect(try journal.commits()[id]?.snapshot == nil)

        // A deleted file is not answered from the cache.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".pruned"))
        #expect(try journal.commits().isEmpty)
    }
}

private actor ResolveCounter {
    var count = 0
    func increment() { count += 1 }
}

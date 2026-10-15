import XCTest
@testable import Tower

final class NodeSelectionTests: XCTestCase {
    @MainActor
    func testSubscriptionInfoNodesAreVisibleByDefaultAndCanBeFiltered() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-info-filter-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PersistenceStore(fileURL: fileURL)
        let source = SubscriptionSource(name: "机场", urlString: "https://example.com/sub")
        let normal = ProxyNode(
            sourceID: source.id, kind: .shadowsocks, name: "香港 01",
            server: "hk.example.com", port: 443, rawURI: "ss://normal"
        )
        let info = ProxyNode(
            sourceID: source.id, kind: .shadowsocks, name: "剩余流量：10 GB",
            server: "1.1.1.1", port: 1, rawURI: "ss://info",
            isSubscriptionMetadata: true
        )
        try store.save(AppSnapshot(
            subscriptions: [source], nodes: [normal, info],
            selectedPresetID: AppModel.defaultRuleSchemeID, selectedTarget: .surge
        ))

        let model = AppModel(persistence: store, arguments: [])
        XCTAssertEqual(model.availableNodes.count, 2)

        model.setFilterSubscriptionInfoNodes(true)
        XCTAssertEqual(model.availableNodes.map(\.id), [normal.id])
        XCTAssertEqual(try store.load()?.filterSubscriptionInfoNodes, true)
    }

    @MainActor
    func testSubscriptionInfoSettingControlsNodeOnlyExportWithoutCreatingSkippedNodes() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-info-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PersistenceStore(fileURL: fileURL)
        let normal = ProxyNode(
            kind: .shadowsocks, name: "香港 01", server: "hk.example.com", port: 443,
            cipher: "aes-128-gcm", password: "secret", rawURI: "ss://normal"
        )
        let info = ProxyNode(
            kind: .shadowsocks, name: "剩余流量：10 GB", server: "1.1.1.1", port: 1,
            cipher: "aes-128-gcm", password: "notice", rawURI: "ss://info",
            isSubscriptionMetadata: true
        )
        try store.save(AppSnapshot(
            subscriptions: [], nodes: [normal, info],
            selectedPresetID: AppModel.defaultRuleSchemeID, selectedTarget: .hiddify
        ))
        let model = AppModel(persistence: store, arguments: [])

        let visible = model.configuration(target: .hiddify, contentMode: .nodesOnly)
        XCTAssertEqual(visible.supportedNodeCount, 2)
        XCTAssertEqual(visible.skippedNodeCount, 0)

        model.setFilterSubscriptionInfoNodes(true)
        let filtered = model.configuration(target: .hiddify, contentMode: .nodesOnly)
        XCTAssertEqual(filtered.supportedNodeCount, 1)
        XCTAssertEqual(filtered.skippedNodeCount, 0)
    }

    @MainActor
    func testSubscriptionNameCanBeAppendedWithoutChangingStoredNode() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-source-suffix-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PersistenceStore(fileURL: fileURL)
        let source = SubscriptionSource(name: "云帆", urlString: "https://example.com/sub")
        let node = ProxyNode(
            sourceID: source.id, kind: .shadowsocks, name: "香港 01",
            server: "hk.example.com", port: 443, rawURI: "ss://node"
        )
        try store.save(AppSnapshot(
            subscriptions: [source], nodes: [node],
            selectedPresetID: AppModel.defaultRuleSchemeID, selectedTarget: .surge
        ))
        let model = AppModel(persistence: store, arguments: [])

        model.setAppendSubscriptionNameToNodes(true)

        XCTAssertEqual(model.nodeForPresentation(node).name, "香港 01 · 云帆")
        XCTAssertEqual(model.nodes.first?.name, "香港 01")
        XCTAssertTrue(model.configuration().content.contains("香港 01 · 云帆"))
    }

    @MainActor
    func testExcludedNodesStayManagedButAreNotGeneratedAndPersist() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-node-selection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PersistenceStore(fileURL: fileURL)
        let source = SubscriptionSource(name: "机场", urlString: "https://example.com/sub")
        let node = ProxyNode(
            sourceID: source.id,
            kind: .shadowsocks,
            name: "香港 01",
            server: "hk.example.com",
            port: 443,
            cipher: "aes-128-gcm",
            password: "secret",
            rawURI: "ss://example"
        )
        try store.save(AppSnapshot(
            subscriptions: [source],
            nodes: [node],
            selectedPresetID: AppModel.defaultRuleSchemeID,
            selectedTarget: .surge
        ))

        let model = AppModel(persistence: store, arguments: [])
        model.setNode(node, included: false)

        XCTAssertEqual(model.availableNodes.map(\.id), [node.id])
        XCTAssertTrue(model.enabledNodes.isEmpty)

        let reloaded = AppModel(persistence: store, arguments: [])
        XCTAssertFalse(reloaded.isNodeIncluded(node))
        XCTAssertTrue(reloaded.enabledNodes.isEmpty)
    }

    @MainActor
    func testBulkNodeSelectionChangesAllVisibleNodesAndPersistsOnce() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-bulk-node-selection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PersistenceStore(fileURL: fileURL)
        let nodes = (1...3).map { index in
            ProxyNode(
                kind: .shadowsocks,
                name: "节点 \(index)",
                server: "node-\(index).example.com",
                port: 443,
                rawURI: "ss://\(index)"
            )
        }
        try store.save(AppSnapshot(
            subscriptions: [],
            nodes: nodes,
            selectedPresetID: AppModel.defaultRuleSchemeID,
            selectedTarget: .surge
        ))
        let model = AppModel(persistence: store, arguments: [])

        model.setNodes(Array(nodes.prefix(2)), included: false)
        XCTAssertEqual(model.enabledNodes.map(\.id), [nodes[2].id])

        model.setNodes(Array(nodes.prefix(2)), included: true)
        XCTAssertEqual(Set(model.enabledNodes.map(\.id)), Set(nodes.map(\.id)))
        XCTAssertNil(try store.load()?.excludedNodeIDs)
    }

    @MainActor
    func testSavedNameConditionFiltersNewNodesAndBothExportModes() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-export-name-filter-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PersistenceStore(fileURL: fileURL)
        let source = SubscriptionSource(name: "Airport", urlString: "https://example.com/sub")
        func node(_ name: String) -> ProxyNode {
            ProxyNode(sourceID: source.id, kind: .shadowsocks, name: name,
                server: "example.com", port: 443, cipher: "aes-128-gcm",
                password: "test", rawURI: "ss://test")
        }
        let initial = [node("US IEPL 01"), node("US 普通 02")]
        try store.save(AppSnapshot(subscriptions: [source], nodes: initial,
            selectedPresetID: AppModel.defaultRuleSchemeID, selectedTarget: .surge))

        let model = AppModel(persistence: store, arguments: [])
        try model.setNodeExportNameFilter(.init(pattern: "(?i)IEPL", ignoresCase: true))
        XCTAssertEqual(model.enabledNodes.map(\.name), ["US IEPL 01"])
        XCTAssertEqual(model.configuration(target: .hiddify, contentMode: .nodesOnly).supportedNodeCount, 1)
        XCTAssertEqual(model.configuration(target: .surge, contentMode: .fullConfiguration).supportedNodeCount, 1)
        XCTAssertFalse(model.isNodeAllowedByName(initial[1]))

        let restored = AppModel(persistence: store, arguments: [])
        XCTAssertEqual(restored.nodeExportNameFilter?.pattern, "(?i)IEPL")
        restored.nodes.append(contentsOf: [node("SG iepl 03"), node("SG 普通 04")])
        XCTAssertEqual(restored.enabledNodes.map(\.name), ["US IEPL 01", "SG iepl 03"])
        XCTAssertEqual(restored.configuration(target: .hiddify, contentMode: .nodesOnly).supportedNodeCount, 2)
        for target in ClientTarget.allCases {
            for mode in target.supportedContentModes {
                let output = restored.configuration(target: target, contentMode: mode)
                XCTAssertEqual(output.supportedNodeCount, 2, "\(target) \(mode)")
            }
        }
        restored.setNode(initial[0], included: false)
        XCTAssertThrowsError(try restored.setNodeExportNameFilter(.init(pattern: "[", ignoresCase: true)))
        XCTAssertEqual(restored.enabledNodes.count, 1)
        try restored.setNodeExportNameFilter(.init(pattern: "  \n", ignoresCase: true))
        XCTAssertNil(restored.nodeExportNameFilter)
        XCTAssertNil(try store.load()?.nodeExportNameFilter)
        XCTAssertEqual(restored.enabledNodes.count, 3)
        XCTAssertFalse(restored.isNodeIncluded(initial[0]))
    }

    @MainActor
    func testTogglingNodesReusesNameConditionMatches() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-name-filter-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PersistenceStore(fileURL: fileURL)
        let source = SubscriptionSource(name: "Airport", urlString: "https://example.com/sub")
        func node(_ name: String) -> ProxyNode {
            ProxyNode(sourceID: source.id, kind: .shadowsocks, name: name,
                server: "example.com", port: 443, cipher: "aes-128-gcm",
                password: "test", rawURI: "ss://test")
        }
        let initial = [node("US IEPL 01"), node("US 普通 02"), node("JP IEPL 03")]
        try store.save(AppSnapshot(subscriptions: [source], nodes: initial,
            selectedPresetID: AppModel.defaultRuleSchemeID, selectedTarget: .surge))

        let model = AppModel(persistence: store, arguments: [])
        try model.setNodeExportNameFilter(.init(pattern: "IEPL", ignoresCase: true))
        XCTAssertEqual(model.enabledNodes.map(\.name), ["US IEPL 01", "JP IEPL 03"])
        let evaluations = model.nodeNameFilterEvaluationCount

        for included in [false, true, false] {
            model.setNode(initial[0], included: included)
            XCTAssertEqual(model.enabledNodes.map(\.name),
                           included ? ["US IEPL 01", "JP IEPL 03"] : ["JP IEPL 03"])
        }
        XCTAssertEqual(model.nodeNameFilterEvaluationCount, evaluations,
                       "勾选节点不应重新执行名称匹配")
        XCTAssertNil(model.nodeExportNameFilterError)

        model.nodes.append(node("SG iepl 04"))
        XCTAssertEqual(model.enabledNodes.map(\.name), ["JP IEPL 03", "SG iepl 04"])
        XCTAssertEqual(model.nodeNameFilterEvaluationCount, evaluations + 1)
    }
}

import XCTest
@testable import Tower

final class Issue33ReproductionTests: XCTestCase {
    func testLegacyRestoreKeepsSelectedNodesAndGroupTypes() throws {
        let text = """
        proxy-providers:
          all-proxies: {type: http, url: 'https://example.com/sub'}
        proxy-groups:
          - {name: Manual, type: select, use: [all-proxies]}
          - {name: Auto, type: url-test, use: [all-proxies], interval: 300}
          - {name: HK, type: select, use: [all-proxies], filter: HK}
        rules: ['MATCH,Manual']
        """
        let parser = RuleSchemeParser()
        let fresh = try parser.parse(text: text, id: "issue33", name: "Self-Configuration", summary: "", useSelectedNodes: true)
        let nodes = (0..<370).map { ProxyNode(kind: .trojan, name: $0 < 55 ? "HK \($0)" : "US \($0)", server: "example.com", port: 443, password: "test", rawURI: "") }
        // A legacy persisted group lacks sourceType. Regional metadata may already
        // be current, e.g. after a separate edit/import migration.
        var legacy = fresh
        legacy.groups = fresh.groups.map { group in
            if group.name == "HK" { return group }
            return RuleSchemeGroup(name: group.name, kind: group.kind, members: group.members,
                                   interval: group.interval)
        }
        let restored = parser.restoringLegacySmartGroups(in: legacy)
        XCTAssertEqual(try NodeNameFilterMatcher.preview(".*", candidates: nodes.map { [$0.name] }, caseInsensitive: false).count, 370)
        for target in [ClientTarget.clash, .singBox, .shadowrocket] {
            let before = ConfigurationGenerator().generate(nodes: nodes, scheme: fresh, target: target)
            let after = ConfigurationGenerator().generate(nodes: nodes, scheme: restored, target: target)
            XCTAssertEqual(before.content, after.content, target.rawValue)
        }
        XCTAssertNil(restored.groups[0].parameters?["use"])
        XCTAssertEqual(parser.restoringLegacySmartGroups(in: restored), restored)
    }
    func testAlreadyMigratedTemplateIsRepairedButRealBindingsRemain() throws {
        let source = """
        proxy-groups:
          - {name: Manual, type: select, use: [all-proxies]}
        rules: ['MATCH,Manual']
        """
        let parser = RuleSchemeParser()
        let broken = try parser.parse(text: source, id: "legacy", name: "Legacy", summary: "")
        XCTAssertNotNil(broken.groups[0].sourceType)
        let repaired = parser.restoringLegacySmartGroups(in: broken)
        XCTAssertNil(repaired.groups[0].parameters?["use"])
        let bound = try parser.parse(text: "proxy-providers:\n  all-proxies: {type: http, url: 'https://example.com/sub'}\n" + source,
                                     id: "bound", name: "Bound", summary: "")
        XCTAssertEqual(parser.restoringLegacySmartGroups(in: bound), bound)
    }

    func testMissingOrUnreadableSourceRepairsPersistedGroupsAcrossAllTargets() throws {
        let source = """
        proxy-groups:
          - {name: Manual, type: select, use: [all-proxies]}
          - {name: Auto, type: url-test, use: [all-proxies], interval: 300}
          - {name: HK, type: select, use: [all-proxies], filter: HK}
        rules: ['MATCH,Manual']
        """
        let parser = RuleSchemeParser()
        let parsed = try parser.parse(text: source, id: "legacy", name: "Self-Configuration", summary: "custom")
        let expected = parser.restoringLegacySmartGroups(in: parsed)
        let nodes = ["HK one", "US two"].map {
            ProxyNode(kind: .trojan, name: $0, server: "example.com", port: 443, password: "test", rawURI: "")
        }
        for rawSource: String? in [nil, "", "invalid legacy text"] {
            var persisted = parsed
            persisted.rawConfigurationText = rawSource
            // Exercise the on-disk representation, not only in-memory migration.
            let decoded = try JSONDecoder().decode(RuleScheme.self, from: JSONEncoder().encode(persisted))
            let repaired = parser.restoringLegacySmartGroups(in: decoded)
            XCTAssertEqual(repaired.groups, expected.groups)
            XCTAssertEqual(repaired.rulesets, decoded.rulesets)
            XCTAssertEqual(repaired.rawConfigurationText, rawSource)
            XCTAssertEqual(repaired.summary, decoded.summary)
            XCTAssertEqual(parser.restoringLegacySmartGroups(in: repaired), repaired)
            for target in ClientTarget.allCases {
                let actual = ConfigurationGenerator().generate(nodes: nodes, scheme: repaired, target: target)
                let reference = ConfigurationGenerator().generate(nodes: nodes, scheme: expected, target: target)
                XCTAssertEqual(actual.content, reference.content, target.rawValue)
            }
        }
    }

    func testSourceLessMigrationPreservesExplicitBindingsAndTags() throws {
        let parser = RuleSchemeParser()
        let source = """
        proxy-providers:
          airport: {type: http, url: 'https://example.com/sub'}
        proxy-groups:
          - {name: Manual, type: select, use: [airport]}
        rules: ['MATCH,Manual']
        """
        var bound = try parser.parse(text: source, id: "bound", name: "Bound", summary: "")
        bound.rawConfigurationText = nil
        XCTAssertEqual(parser.restoringLegacySmartGroups(in: bound), bound)
        var tagged = bound
        let group = tagged.groups[0]
        var parameters = group.parameters ?? [:]
        parameters.removeValue(forKey: "tower-source-bindings")
        parameters["tower-source-tags"] = "[\"airport\"]"
        tagged.groups[0] = RuleSchemeGroup(name: group.name, kind: group.kind, members: group.members,
            sourceType: group.sourceType, sourceFormat: group.sourceFormat, parameters: parameters)
        XCTAssertEqual(parser.restoringLegacySmartGroups(in: tagged), tagged)
    }

}

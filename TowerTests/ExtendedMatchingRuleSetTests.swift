import XCTest
@testable import Tower

final class ExtendedMatchingRuleSetTests: XCTestCase {
    private let remoteExtendedTargets: [ClientTarget] = [.clash, .clashApple, .clashVerge, .clashMac, .flClash, .mihomoParty, .clashMi]
    private let url = URL(string: "https://example.com/AI.list")!

    private func withResource(_ body: String, _ check: (RuleSchemeRepository, RuleScheme) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RuleDownloadStore(folderURL: folder)
        try store.store(body, for: url)
        let scheme = RuleScheme(id: "extended", name: "Extended", summary: "", groups: [], rulesets: [
            .init(groupName: "DIRECT", resource: .remote(url)),
            .init(groupName: "DIRECT", resource: .inline("FINAL"))
        ])
        try check(RuleSchemeRepository(downloadStore: store), scheme)
    }

    func testSurgeKeepsMixedPlainAndExtendedRulesInOriginalRemoteResource() throws {
        let body = "DOMAIN,plain.example\nDOMAIN-SUFFIX,cici.com,extended-matching\nDOMAIN-SUFFIX,dola.com,extended-matching\n"
        try withResource(body) { repository, scheme in
            for target: ClientTarget in [.surge, .surgeMac] {
                let plan = RuleSetEmissionPlanner(repository: repository).plan(for: scheme, target: target, preferRuleSets: true)
                XCTAssertEqual(plan.remoteResources.map(\.url), [url])
                XCTAssertTrue(plan.inlineRules.isEmpty)
                let output = ConfigurationGenerator().generate(nodes: [], scheme: scheme, target: target, schemes: repository, preferRuleSets: true)
                XCTAssertTrue(output.content.contains("RULE-SET,\(url.absoluteString),DIRECT"))
                XCTAssertFalse(output.content.contains("RULE-SET,\(url.absoluteString),DIRECT,extended-matching"))
                XCTAssertFalse(output.content.contains("DOMAIN-SUFFIX,cici.com"))
                let inline = ConfigurationGenerator().generate(nodes: [], scheme: scheme, target: target, schemes: repository, preferRuleSets: false)
                XCTAssertTrue(inline.content.contains("DOMAIN-SUFFIX,cici.com,DIRECT,extended-matching"))
                XCTAssertTrue(inline.content.contains("DOMAIN,plain.example,DIRECT"))
            }
        }
    }

    func testMihomoAndStashTargetsKeepExtendedDomainListAsRemoteProvider() throws {
        try withResource("DOMAIN,plain.example\nDOMAIN-SUFFIX,cici.com,extended-matching") { repository, scheme in
            for target in remoteExtendedTargets {
                let plan = RuleSetEmissionPlanner(repository: repository).plan(for: scheme, target: target, preferRuleSets: true)
                XCTAssertEqual(plan.remoteResources.map(\.url), [url])
                XCTAssertTrue(plan.inlineRules.isEmpty)
                let output = ConfigurationGenerator().generate(nodes: [], scheme: scheme, target: target, schemes: repository, preferRuleSets: true)
                XCTAssertTrue(output.content.contains("rule-providers:"))
                XCTAssertTrue(output.content.contains("RULE-SET,"))
                XCTAssertFalse(output.content.contains("DOMAIN-SUFFIX,cici.com"))
                XCTAssertTrue(output.content.contains("format: text"))
                XCTAssertTrue(output.diagnostics.isEmpty)
                let inline = RuleSetEmissionPlanner(repository: repository).plan(for: scheme, target: target, preferRuleSets: false)
                XCTAssertTrue(inline.remoteResources.isEmpty)
            }
        }
    }

    func testUnverifiedTargetsDoNotReceiveTheSurgeResourceUnchanged() throws {
        try withResource("DOMAIN-SUFFIX,example.com,extended-matching") { repository, scheme in
            for target in ClientTarget.allCases where target != .surge && target != .surgeMac && !remoteExtendedTargets.contains(target) {
                let plan = RuleSetEmissionPlanner(repository: repository).plan(for: scheme, target: target, preferRuleSets: true)
                XCTAssertTrue(plan.remoteResources.isEmpty, target.rawValue)
                XCTAssertEqual(plan.inlineRules.first?.line, "DOMAIN-SUFFIX,example.com,extended-matching", target.rawValue)
            }
        }
    }

    func testSurgeRejectsPoliciesUnknownOptionsAndPreMatchingInExternalLists() throws {
        for body in ["DOMAIN,example.com,Proxy", "DOMAIN,example.com,unknown-option", "DOMAIN,example.com,pre-matching", "DOMAIN,example.com,extended-matching=true", "IP-CIDR,192.0.2.0/24,extended-matching"] {
            try withResource(body) { repository, scheme in
                for target: ClientTarget in [.surge, .surgeMac] + remoteExtendedTargets {
                    let plan = RuleSetEmissionPlanner(repository: repository).plan(for: scheme, target: target, preferRuleSets: true)
                    XCTAssertTrue(plan.remoteResources.isEmpty, body)
                }
            }
        }
    }

    func testExistingNoResolveResourcesRemainRemote() throws {
        try withResource("DOMAIN,example.com\nIP-CIDR,192.0.2.0/24,no-resolve") { repository, scheme in
            for target: ClientTarget in [.surge, .surgeMac, .clashMi, .clash] {
                let plan = RuleSetEmissionPlanner(repository: repository).plan(for: scheme, target: target, preferRuleSets: true)
                XCTAssertEqual(plan.remoteResources.map(\.url), [url], target.rawValue)
            }
        }
    }
}

import XCTest
@testable import Tower

/// Findings from the Codex review of 2026-09-29 (.artifacts/codex-review,
/// local only), kept as regressions.
final class CodexReviewRegressionTests: XCTestCase {
    private let node = ProxyNode(kind: .trojan, name: "Test", server: "example.com", port: 443, password: "test", rawURI: "")

    func testStrictDNSWithMixedSelectorMustNotFallBackToDomestic() throws {
        var scheme = try RuleSchemeParser().parse(
            text: "[Proxy Group]\nProxy = select,Test,DIRECT\n[Rule]\nDOMAIN-SUFFIX,private.example,DIRECT\nFINAL,Proxy",
            id: "review", name: "Review", summary: "")
        scheme.networkSettings = RuleSchemeNetworkSettings(
            dnsServers: ["223.5.5.5"], encryptedDNSServers: ["https://223.5.5.5/dns-query"],
            remoteDNSServers: ["https://8.8.8.8/dns-query"], dnsProtectionMode: .strict)
        let result = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: .clashMi)
        XCTAssertFalse(result.hasInvalidPolicyReferences)
        XCTAssertFalse(result.content.contains("  nameserver:\n    - https://223.5.5.5/dns-query\n"),
                       "Strict mode silently uses domestic nameserver with a valid Test,DIRECT selector")
        XCTAssertTrue(result.content.contains("8.8.8.8/dns-query#DNS 自动选择&ecs="), "The configured remote resolver disappeared")
        // The dedicated group lists only nodes and stays out of the way.
        XCTAssertTrue(result.content.contains("  - name: \"DNS 自动选择\"\n    type: url-test\n"), result.content)
        XCTAssertTrue(result.content.contains("    hidden: true\n"), result.content)
    }

    func testSourceGeoIPAndASNAreNotConvertedToDestination() throws {
        for body in ["GEOIP,CN,src", "IP-ASN,13335,src", "GEOIP,LAN,src"] {
            for useSets in [false, true] {
                let condition = try XCTUnwrap(RoutingRuleCapabilities.singBoxCondition(body, localRuleSets: useSets))
                let source = condition["source_ip_cidr"] != nil || condition["source_ip_is_private"] != nil
                    || condition["rule_set_ip_cidr_match_source"] as? Bool == true
                XCTAssertTrue(source, "Source direction lost for \(body), localRuleSets=\(useSets), keys=\(condition.keys.sorted())")
            }
        }
    }

    func testWildcardRejectMustNotBroadenToApexDomain() throws {
        let scheme = try RuleSchemeParser().parse(
            text: "[Proxy Group]\nProxy = select,Test\n[Rule]\nDOMAIN-WILDCARD,*.example.com,REJECT\nFINAL,Proxy",
            id: "review", name: "Review", summary: "")
        let result = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: .loon)
        XCTAssertFalse(result.hasInvalidPolicyReferences)
        XCTAssertFalse(result.content.contains("DOMAIN-SUFFIX,example.com,REJECT\n"),
                       "Wildcard reject now also blocks example.com, which the original rule did not match")
        XCTAssertTrue(result.content.contains("AND,((DOMAIN-SUFFIX,example.com),(NOT,((DOMAIN,example.com)))),REJECT\n"), result.content)
    }

    func testExplicitDirectChoiceSurvivesAnUnmatchedOptionalPattern() throws {
        let scheme = try RuleSchemeParser().parse(text: """
        [custom]
        ruleset=Business,[]FINAL
        custom_proxy_group=Business`select`[]Domestic`[]Proxy
        custom_proxy_group=Domestic`select`[]DIRECT`OptionalNode
        custom_proxy_group=Proxy`select`.*
        """, id: "review", name: "Review", summary: "")
        let result = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: .clashMi)
        XCTAssertFalse(result.hasInvalidPolicyReferences)
        XCTAssertTrue(result.content.contains("name: \"Business\"\n    type: select\n    proxies:\n      - \"Domestic\""),
                      "Explicit DIRECT-first Domestic group was removed, changing Business to default to Proxy")
    }
}

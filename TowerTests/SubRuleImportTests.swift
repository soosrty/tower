import XCTest
@testable import Tower

/// mihomo `SUB-RULE` / `sub-rules` (issue #7, echs-top/proxy). Tower used to
/// read the sub-rule name as a policy group, so every export failed with
/// "规则目标不存在：sub-telegram".
final class SubRuleImportTests: XCTestCase {
    private let node = ProxyNode(kind: .trojan, name: "HK 01", server: "example.com", port: 443, password: "p", rawURI: "")

    private func parse(_ text: String) throws -> RuleScheme {
        try RuleSchemeParser().parse(data: Data(text.utf8), id: "sub", name: "Sub", summary: "", isBundled: false)
    }

    /// Trimmed from echs-top/proxy `mihomo.yaml`: a rule-set condition whose
    /// sub-rules send QUIC one way and everything else another.
    private let echs = """
    domain: &domain { type: http, interval: 86400, behavior: domain, format: mrs }
    rule-providers:
      ai: { <<: *domain, url: 'https://example.com/mrs/ai.mrs', path: ./rules/ai.mrs }
      telegram_ip: { type: http, behavior: ipcidr, format: mrs, url: 'https://example.com/mrs/telegram.mrs', path: ./rules/tg.mrs }
    quic: &quic 'AND,((NETWORK,udp),(DST-PORT,443)),代理QUIC'
    proxy-groups:
      - {name: 代理连接, type: select, proxies: [DIRECT], include-all: true}
      - {name: 代理QUIC, type: select, proxies: [REJECT, 代理连接]}
      - {name: 国外AI, type: select, proxies: [代理连接]}
      - {name: TELEGRAM, type: select, proxies: [代理连接]}
    rules:
      - SUB-RULE,(RULE-SET,telegram_ip,no-resolve),sub-telegram
      - SUB-RULE,(RULE-SET,ai),sub-ai
      - *quic
      - MATCH,代理连接
    sub-rules:
      sub-telegram: [*quic,'MATCH,TELEGRAM']
      sub-ai: [*quic,'MATCH,国外AI']
    """

    func testRuleSetSubRulesFlattenInOrder() throws {
        let scheme = try parse(echs)
        let summary = scheme.rulesets.map { ruleset -> String in
            switch ruleset.resource {
            case .remote(let url): return "\(ruleset.groupName) <- \(url.lastPathComponent) \(ruleset.options ?? [])"
            case .inline(let body): return "\(ruleset.groupName) <- \(body)"
            }
        }
        XCTAssertEqual(summary, [
            "代理QUIC <- AND,((RULE-SET,telegram_ip,no-resolve),(AND,((NETWORK,udp),(DST-PORT,443))))",
            "TELEGRAM <- telegram.mrs [\"no-resolve\"]",
            "代理QUIC <- AND,((RULE-SET,ai),(AND,((NETWORK,udp),(DST-PORT,443))))",
            "国外AI <- ai.mrs []",
            "代理QUIC <- AND,((NETWORK,udp),(DST-PORT,443))",
            "代理连接 <- FINAL",
        ])
        XCTAssertFalse(scheme.groups.contains { $0.name.hasPrefix("sub-") })
    }

    func testFlattenedSchemeExportsWithANoticeForTheRuleSetInsideAND() throws {
        let scheme = try parse(echs)
        for target in [ClientTarget.clashMi, .surge, .singBox] {
            let result = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: target)
            XCTAssertFalse(result.hasInvalidPolicyReferences, "\(target.name): \(result.diagnostics)")
            XCTAssertFalse(result.content.contains("sub-telegram"), target.name)
            // A rule set inside AND has no written form in Tower's model, so
            // those two QUIC branches are skipped and named.
            XCTAssertTrue(result.diagnostics.contains { $0.contains("RULE-SET,telegram_ip") }, "\(target.name): \(result.diagnostics)")
        }
        // mihomo references the MRS lists directly for the MATCH branches.
        let clash = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: .clashMi).content
        XCTAssertTrue(clash.contains("telegram.mrs"), clash)
        XCTAssertTrue(clash.contains(",TELEGRAM,no-resolve"), clash)
    }

    func testInlineAndNestedSubRules() throws {
        let scheme = try parse("""
        proxy-groups:
          - {name: P, type: select, proxies: [DIRECT]}
          - {name: Q, type: select, proxies: [DIRECT]}
        rules:
          - SUB-RULE,(NETWORK,tcp),outer
          - MATCH,P
        sub-rules:
          outer:
            - DOMAIN,a.example,P
            - SUB-RULE,(DOMAIN-SUFFIX,b.example),inner
            - MATCH,Q
          inner:
            - DST-PORT,443,P
        """)
        let bodies = scheme.rulesets.compactMap { ruleset -> String? in
            guard case .inline(let body) = ruleset.resource else { return nil }
            return "\(body) -> \(ruleset.groupName)"
        }
        XCTAssertEqual(bodies, [
            "AND,((NETWORK,tcp),(DOMAIN,a.example)) -> P",
            "AND,((AND,((NETWORK,tcp),(DOMAIN-SUFFIX,b.example))),(DST-PORT,443)) -> P",
            "NETWORK,tcp -> Q",
            "FINAL -> P",
        ])
        let surge = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: .surge)
        XCTAssertFalse(surge.hasInvalidPolicyReferences, "\(surge.diagnostics)")
        // Surge spells the transport condition PROTOCOL.
        XCTAssertTrue(surge.content.contains("AND,((PROTOCOL,TCP),(DOMAIN,a.example)),P\n"), surge.content)
        XCTAssertTrue(surge.content.contains("PROTOCOL,TCP,Q\n"), surge.content)
    }

    func testUnknownOrCyclicSubRulesAreRejected() {
        XCTAssertThrowsError(try parse("""
        proxy-groups:
          - {name: P, type: select, proxies: [DIRECT]}
        rules:
          - SUB-RULE,(NETWORK,tcp),missing
          - MATCH,P
        """))
        XCTAssertThrowsError(try parse("""
        proxy-groups:
          - {name: P, type: select, proxies: [DIRECT]}
        rules:
          - SUB-RULE,(NETWORK,tcp),loop
          - MATCH,P
        sub-rules:
          loop:
            - SUB-RULE,(DOMAIN,a.example),loop
        """))
    }
}

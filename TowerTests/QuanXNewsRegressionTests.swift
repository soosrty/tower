import XCTest
@testable import Tower

final class QuanXNewsRegressionTests: XCTestCase {
    func testPluginMuxSurvivesParsingPersistenceAndExport() throws {
        for flag in ["false", "true"] {
            let source = """
            proxies:
              - name: SS WS
                type: ss
                server: example.com
                port: 443
                cipher: aes-128-gcm
                password: fixture
                plugin: v2ray-plugin
                plugin-opts:
                  mode: websocket
                  tls: true
                  mux: \(flag)
                  host: ws.example.com
                  path: /ws
            """
            let node = try XCTUnwrap(SubscriptionParser().parse(data: Data(source.utf8)).nodes.first)
            XCTAssertEqual(node.pluginMux, flag == "true")
            let restored = try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(node))
            XCTAssertEqual(restored.pluginMux, node.pluginMux)
            let generator = ConfigurationGenerator()
            let qx = generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: .quanx)
            XCTAssertEqual(qx.supportedNodeCount, flag == "false" ? 1 : 0)
            let clash = generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: .clash)
            XCTAssertTrue(clash.content.contains("      mux: \(flag)"))
            let link = ProxyNodeShareLinkGenerator().canonicalLink(for: node)
            let reparsed = try XCTUnwrap(SubscriptionParser().parse(data: Data(link.utf8)).nodes.first)
            XCTAssertEqual(reparsed.pluginMux, node.pluginMux)
        }
        let unknown = ProxyNode(kind: .shadowsocks, name: "Unknown MUX", server: "example.com", port: 443,
            cipher: "aes-128-gcm", password: "fixture", transport: "ws", plugin: "v2ray-plugin", tls: true, rawURI: "")
        XCTAssertEqual(output(unknown).skippedNodeCount, 1)
    }

    func testEgernAnyTLSKeepsCertificateVerificationEnabled() {
        let node = ProxyNode(kind: .anytls, name: "AnyTLS", server: "example.com", port: 443, password: "fixture", tls: true, rawURI: "")
        let content = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: .egern).content
        XCTAssertTrue(content.contains("      skip_tls_verify: false"))
    }

    func testEgernVisionAndTrojanWebSocketSchema() {
        let vless = ProxyNode(kind: .vless, name: "Vision", server: "example.com", port: 443,
            uuid: "11111111-1111-4111-8111-111111111111", tls: true, sni: "tls.example.com",
            realityPublicKey: "fixture", realityShortID: "1234", flow: "xtls-rprx-vision", rawURI: "")
        let generator = ConfigurationGenerator()
        let content = generator.generate(nodes: [vless], preset: RulePreset.builtIns[0], target: .egern).content
        XCTAssertTrue(content.contains("      flow: \"xtls-rprx-vision\""))
        XCTAssertTrue(content.contains("      transport:\n        tls:"))
        XCTAssertTrue(content.contains("          reality:\n            public_key:"))
        XCTAssertFalse(content.contains("\n      reality:"))
        let trojan = ProxyNode(kind: .trojan, name: "WS", server: "example.com", port: 443,
            password: "fixture", transport: "ws", tls: true, hostHeader: "ws.example.com", path: "/ws", rawURI: "")
        let ws = generator.generate(nodes: [trojan], preset: RulePreset.builtIns[0], target: .egern).content
        XCTAssertTrue(ws.contains("      websocket:\n        path: \"/ws\""))
        XCTAssertTrue(ws.contains("        host: \"ws.example.com\""))
        XCTAssertFalse(ws.contains("      transport:"))
    }

    func testLoonTLSCredentialsUseUnquotedSimpleUsername() {
        for kind: ProxyKind in [.socks5, .http] {
            let node = ProxyNode(kind: kind, name: "TLS", server: "example.com", port: 443,
                                 password: "secret", username: "tower", tls: true,
                                 sni: "cover.example.com", alpn: "http/1.1", rawURI: "")
            let result = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: .loon)
            XCTAssertTrue(result.content.contains(",443,tower,\"secret\""))
            XCTAssertTrue(result.content.contains("sni=cover.example.com"))
            XCTAssertTrue(result.content.contains("alpn=http/1.1"))
            if kind == .socks5 { XCTAssertTrue(result.content.contains("over-tls=true")) }
        }
        let complex = ProxyNode(kind: .http, name: "Complex", server: "example.com", port: 80,
                                password: "secret", username: "user,name", rawURI: "")
        let output = ConfigurationGenerator().generate(nodes: [complex], preset: RulePreset.builtIns[0], target: .loon)
        XCTAssertTrue(output.content.contains(",80,\"user,name\",\"secret\""))
    }

    func testLoonPreservesConfirmedAnyTLSAndTrojanReality() {
        for kind: ProxyKind in [.anytls, .trojan] {
            var node = ProxyNode(kind: kind, name: "Reality", server: "example.com", port: 443,
                                 password: "fixture", tls: true, sni: "cover.example.com", rawURI: "")
            node.realityPublicKey = "fixture-public-key"
            node.realityShortID = "0123456789abcdef"
            let result = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: .loon)
            XCTAssertEqual(result.supportedNodeCount, 1)
            XCTAssertTrue(result.content.contains("public-key=\"fixture-public-key\""))
            XCTAssertTrue(result.content.contains("short-id=0123456789abcdef"))
            XCTAssertTrue(result.content.contains("sni=cover.example.com"))
        }
    }

    func testClashAppleSkipsUnsupportedSecurityWithoutDanglingMembers() {
        var nodes = [ProxyNode]()
        for kind in [ProxyKind.anytls, .socks5, .http] {
            nodes.append(ProxyNode(kind: kind, name: "Unsupported-\(kind.rawValue)", server: "example.com", port: 443,
                password: "fixture", tls: true, realityPublicKey: "fixture", rawURI: ""))
        }
        nodes.append(ProxyNode(kind: .shadowsocks, name: "Unsupported-nativeSS", server: "example.com", port: 443,
            cipher: "aes-128-gcm", password: "fixture", tls: true, rawURI: ""))
        nodes.append(ProxyNode(kind: .trojan, name: "WorkingReality", server: "example.com", port: 443,
            password: "fixture", tls: true, realityPublicKey: "fixture", rawURI: ""))
        nodes.append(ProxyNode(kind: .shadowsocks, name: "WorkingPlugin", server: "example.com", port: 443,
            cipher: "aes-128-gcm", password: "fixture", transport: "ws", plugin: "v2ray-plugin", tls: true, rawURI: ""))
        let result = ConfigurationGenerator().generate(nodes: nodes, preset: RulePreset.builtIns[0], target: .clashApple)
        XCTAssertEqual(result.skippedNodeCount, 4)
        XCTAssertEqual(result.supportedNodeCount, 2)
        XCTAssertFalse(result.content.contains("Unsupported-"))
        XCTAssertTrue(result.content.contains("reality-opts:"))
        XCTAssertTrue(result.content.contains("plugin: v2ray-plugin"))
    }

    func testStashSkipsUnrepresentableTLSAndModernTransports() {
        let generator = ConfigurationGenerator()
        for kind: ProxyKind in [.anytls, .trojan, .socks5, .http] {
            var node = ProxyNode(kind: kind, name: "Reality", server: "example.com", port: 443,
                                 password: "fixture", tls: true, rawURI: "")
            node.realityPublicKey = "fixture-public-key"
            node.realityShortID = "0123456789abcdef"
            let result = generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: .clash)
            XCTAssertEqual(result.supportedNodeCount, 0, kind.rawValue)
            XCTAssertEqual(result.skippedNodeCount, 1, kind.rawValue)
        }
        let ss = ProxyNode(kind: .shadowsocks, name: "Native TLS", server: "example.com", port: 443,
                           cipher: "aes-128-gcm", password: "fixture", tls: true, rawURI: "")
        XCTAssertEqual(generator.generate(nodes: [ss], preset: RulePreset.builtIns[0], target: .clash).skippedNodeCount, 1)
        let xhttp = ProxyNode(kind: .vless, name: "XHTTP", server: "example.com", port: 443,
                             uuid: "12345678-1234-1234-1234-123456789abc", transport: "xhttp", tls: true, rawURI: "")
        XCTAssertEqual(generator.generate(nodes: [xhttp], preset: RulePreset.builtIns[0], target: .clash).skippedNodeCount, 1)
        for target: ClientTarget in [.clashApple, .clashMi, .shadowrocket, .karing] {
            XCTAssertEqual(generator.generate(nodes: [xhttp], preset: RulePreset.builtIns[0], target: target).supportedNodeCount, 1)
        }
    }

    func testStashTrojanWebSocketUsesSNI() {
        let node = ProxyNode(kind: .trojan, name: "Trojan WS", server: "192.0.2.1", port: 443,
                             password: "fixture", transport: "ws", tls: true, sni: "tls.example.com",
                             hostHeader: "ws.example.com", path: "/test", rawURI: "")
        let result = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: .clash)
        XCTAssertEqual(result.supportedNodeCount, 1)
        XCTAssertTrue(result.content.contains("    sni: \"tls.example.com\""))
        XCTAssertFalse(result.content.contains("    servername:"))
        XCTAssertTrue(result.content.contains("    network: \"ws\""))
        XCTAssertTrue(result.content.contains("      path: \"/test\""))
        XCTAssertTrue(result.content.contains("        Host: \"ws.example.com\""))
    }

    func testEgernDoesNotStripSSTLSAndModernSnellExports() {
        let generator = ConfigurationGenerator()
        let ss = ProxyNode(kind: .shadowsocks, name: "TLS", server: "example.com", port: 443,
            cipher: "aes-128-gcm", password: "fixture", tls: true, rawURI: "")
        XCTAssertEqual(generator.generate(nodes: [ss], preset: RulePreset.builtIns[0], target: .egern).skippedNodeCount, 1)
        for target: ClientTarget in [.clashApple, .clashMi] {
            for version in [4, 5] {
                let snell = ProxyNode(kind: .snell, name: "Snell", server: "example.com", port: 443,
                    password: "fixture", version: version, rawURI: "")
                XCTAssertEqual(generator.generate(nodes: [snell], preset: RulePreset.builtIns[0], target: target).supportedNodeCount, 1)
            }
        }
    }

    func testShadowrocketYAMLPreservesRealityAndTLS() throws {
        for kind: ProxyKind in [.anytls, .socks5, .http, .shadowsocks] {
            var node = ProxyNode(kind: kind, name: "TLS Fixture", server: "proxy.example.com", port: 443,
                                 cipher: "aes-128-gcm", password: "fixture", tls: true,
                                 sni: "tls.example.com", alpn: "http/1.1", rawURI: "")
            node.realityPublicKey = "k4Uxez0sjl8bKaZH2Vgi8-WDFshML51QkxKFLWFIONk"
            node.realityShortID = "0123456789abcdef"
            let result = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: .shadowrocket)
            XCTAssertEqual(result.supportedNodeCount, 1, kind.rawValue)
            XCTAssertTrue(result.content.contains("    reality-opts:"), kind.rawValue)
            XCTAssertTrue(result.content.contains("      short-id: \"0123456789abcdef\""), kind.rawValue)
            let parsed = try XCTUnwrap(SubscriptionParser().parse(data: Data(result.content.utf8)).nodes.first)
            XCTAssertEqual(parsed.realityPublicKey, node.realityPublicKey, kind.rawValue)
            XCTAssertEqual(parsed.sni, node.sni, kind.rawValue)
            XCTAssertTrue(parsed.tls, kind.rawValue)
        }
        let ss = ProxyNode(kind: .shadowsocks, name: "SS TLS", server: "proxy.example.com", port: 443,
                           cipher: "aes-128-gcm", password: "fixture", tls: true, sni: "tls.example.com", rawURI: "")
        let result = ConfigurationGenerator().generate(nodes: [ss], preset: RulePreset.builtIns[0], target: .shadowrocket)
        XCTAssertTrue(result.content.contains("    tls: true"))
    }

    func testKaringYAMLPreservesRealityOnlyWhereItConnects() throws {
        var anytls = ProxyNode(kind: .anytls, name: "TLS Fixture", server: "proxy.example.com", port: 443,
                               password: "fixture", tls: true, sni: "tls.example.com", alpn: "http/1.1", rawURI: "")
        anytls.realityPublicKey = "k4Uxez0sjl8bKaZH2Vgi8-WDFshML51QkxKFLWFIONk"
        anytls.realityShortID = "0123456789abcdef"
        let result = ConfigurationGenerator().generate(nodes: [anytls], preset: RulePreset.builtIns[0], target: .karing)
        XCTAssertEqual(result.supportedNodeCount, 1)
        XCTAssertTrue(result.content.contains("    reality-opts:"))
        XCTAssertTrue(result.content.contains("      short-id: \"0123456789abcdef\""))
        let parsed = try XCTUnwrap(SubscriptionParser().parse(data: Data(result.content.utf8)).nodes.first)
        XCTAssertEqual(parsed.realityPublicKey, anytls.realityPublicKey)

        // Karing's sing-box core has no SOCKS TLS and no native SS TLS, and its
        // users saw SOCKS5/HTTP Reality fail: these are skipped, not written.
        for kind: ProxyKind in [.socks5, .http, .shadowsocks] {
            var node = ProxyNode(kind: kind, name: "TLS Fixture", server: "proxy.example.com", port: 443,
                                 cipher: "aes-128-gcm", password: "fixture", tls: true,
                                 sni: "tls.example.com", alpn: "http/1.1", rawURI: "")
            if kind != .shadowsocks {
                node.realityPublicKey = anytls.realityPublicKey
                node.realityShortID = anytls.realityShortID
            }
            let skipped = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: .karing)
            XCTAssertEqual(skipped.supportedNodeCount, 0, kind.rawValue)
            XCTAssertEqual(skipped.skippedNodeCount, 1, kind.rawValue)
        }
    }

    func testOptionalAllProtocolLabExport() throws {
        let source = URL(fileURLWithPath: "/tmp/tower-all-lab-source.yaml")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Local lab fixture not installed") }
        let nodes = SubscriptionParser().parse(data: try Data(contentsOf: source)).nodes
        XCTAssertEqual(nodes.count, 25)
        XCTAssertEqual(Set(nodes.map(\.kind)), Set(ProxyKind.allCases.filter { $0 != .unknown }))
        for target: ClientTarget in [.shadowrocket, .quanx, .clash, .singBox, .loon] {
            let result = ConfigurationGenerator().generate(nodes: nodes, preset: RulePreset.builtIns[0], target: target)
            if target == .shadowrocket { XCTAssertEqual(result.supportedNodeCount, 25) }
            let path = URL(fileURLWithPath: "/tmp/tower-all-lab-" + target.rawValue + ".txt")
            try Data(result.content.utf8).write(to: path, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    func testOptionalLocalLabExport() throws {
        let source = URL(fileURLWithPath: "/tmp/tower-qx-lab-source.yaml")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Local lab fixture not installed")
        }
        let nodes = SubscriptionParser().parse(data: try Data(contentsOf: source)).nodes
        XCTAssertEqual(nodes.count, 11)
        let scheme = try RuleSchemeParser().parse(text: """
        [policy]
        static=测试出口, 测试自动, server-tag-regex=.*
        url-latency-benchmark=测试自动, server-tag-regex=.*, check-interval=300, tolerance=50
        [filter_local]
        ip-asn, 13335, 测试出口
        host-wildcard, *.example.com, 测试出口
        final, 测试出口
        """, id: "lab", name: "QuanX Test", summary: "")
        let result = ConfigurationGenerator().generate(nodes: nodes, scheme: scheme, target: .quanx)
        XCTAssertEqual(result.supportedNodeCount, 11)
        let url = URL(fileURLWithPath: "/tmp/tower-qx-lab-export.conf")
        try Data(result.content.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func testClashHTTPArrayFieldsExportAsScalars() throws {
        let yaml = """
        proxies:
          - name: HTTP
            type: vmess
            server: proxy.example.com
            port: 80
            uuid: 23ad6b10-8d1a-40f7-8ad0-e3e35cd32291
            network: http
            http-opts:
              path: ["/qx-test"]
              headers:
                Host: ["http.example.com"]
        """
        let node = try XCTUnwrap(SubscriptionParser().parse(data: Data(yaml.utf8)).nodes.first)
        XCTAssertEqual(node.hostHeader, "http.example.com")
        XCTAssertEqual(node.path, "/qx-test")
        let content = output(node).content
        XCTAssertTrue(content.contains("obfs-host=http.example.com"))
        XCTAssertTrue(content.contains("obfs-uri=/qx-test"))
    }

    private func output(_ node: ProxyNode) -> GeneratedConfiguration {
        ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: .quanx)
    }

    func testTLSProxyPreservesSNIAndALPN() {
        for kind: ProxyKind in [.socks5, .http, .trojan, .anytls, .shadowsocks] {
            let node = ProxyNode(kind: kind, name: "TLS", server: "proxy.example.com", port: 443,
                                 cipher: "aes-128-gcm", password: "fixture", tls: true,
                                 sni: "tls.example.com", alpn: "h2,http/1.1", rawURI: "")
            let content = output(node).content
            XCTAssertTrue(content.contains(kind == .shadowsocks ? "obfs=over-tls" : "over-tls=true"), kind.rawValue)
            XCTAssertTrue(content.contains("tls.example.com"), kind.rawValue)
            XCTAssertTrue(content.contains("tls-alpn=02683208687474702f312e31"), kind.rawValue)
        }
    }

    func testRealityPreservedAcrossTLSProtocols() {
        for kind: ProxyKind in [.socks5, .http, .trojan, .anytls, .shadowsocks, .vmess, .vless] {
            var node = ProxyNode(kind: kind, name: "Reality", server: "proxy.example.com", port: 443,
                                 cipher: "aes-128-gcm", password: "fixture", uuid: "23ad6b10-8d1a-40f7-8ad0-e3e35cd32291",
                                 tls: true, sni: "tls.example.com", rawURI: "")
            node.realityPublicKey = "k4Uxez0sjl8bKaZH2Vgi8-WDFshML51QkxKFLWFIONk"
            node.realityShortID = "0123456789abcdef"
            let content = output(node).content
            XCTAssertTrue(content.contains("reality-base64-pubkey="), kind.rawValue)
            XCTAssertTrue(content.contains("reality-hex-shortid=0123456789abcdef"), kind.rawValue)
        }
    }

    func testVMessHTTPIsExportedWithHTTPTransport() {
        let node = ProxyNode(kind: .vmess, name: "HTTP", server: "proxy.example.com", port: 80,
                             uuid: "23ad6b10-8d1a-40f7-8ad0-e3e35cd32291", transport: "http",
                             hostHeader: "http.example.com", path: "/test", rawURI: "")
        let result = output(node)
        XCTAssertEqual(result.supportedNodeCount, 1)
        XCTAssertTrue(result.content.contains("obfs=http"))
        XCTAssertTrue(result.content.contains("obfs-host=http.example.com"))
        XCTAssertTrue(result.content.contains("obfs-uri=/test"))
    }

    func testNativeASNAndWildcardRulesRoundTrip() throws {
        let scheme = try RuleSchemeParser().parse(text: """
        [policy]
        static=Exit, direct
        [filter_local]
        ip-asn, 13335, Exit
        host-wildcard, *.example.com, Exit
        final, Exit
        """, id: "news", name: "News", summary: "")
        XCTAssertEqual(scheme.rulesets[0].resource, .inline("IP-ASN,13335"))
        XCTAssertEqual(scheme.rulesets[1].resource, .inline("DOMAIN-WILDCARD,*.example.com"))
    }
}

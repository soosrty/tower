import Foundation
import Testing
@testable import Tower

struct ShadowTLSTests {
    static let ssPassword = Data(repeating: 7, count: 32).base64EncodedString()
    static let tlsPassword = "outer%2F+&=secret"
    static let yaml = """
    proxies:
      - name: ShadowTLS fixture
        type: ss
        server: example.com
        port: 443
        cipher: 2022-blake3-aes-256-gcm
        password: "\(ssPassword)"
        plugin: shadow-tls
        plugin-opts:
          host: www.example.com
          password: "\(tlsPassword)"
          version: 3
        udp: false
    """
    static var uri: String {
        let auth = Data("2022-blake3-aes-256-gcm:\(ssPassword)".utf8).base64EncodedString()
        let plugin = "shadow-tls;host=www.example.com;password=\(tlsPassword);version=3"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "ss://\(auth)@example.com:443?plugin=\(plugin)&udp=false#ShadowTLS%20fixture"
    }

    @Test(arguments: [yaml, uri])
    func importsShadowTLS(_ input: String) throws {
        let parsed = SubscriptionParser().parse(data: Data(input.utf8))
        #expect(parsed.nodes.count == 1)
        #expect(parsed.rejectedLineCount == 0)
        let node = try #require(parsed.nodes.first)
        #expect(node.password == Self.ssPassword)
        #expect(node.shadowTLS?.password == Self.tlsPassword)
        #expect(node.shadowTLS?.host == "www.example.com")
        #expect(node.shadowTLS?.version == 3)
        #expect(node.udpRelayEnabled == false)
    }

    private func fixture() throws -> ProxyNode {
        try #require(SubscriptionParser().parse(data: Data(Self.yaml.utf8)).nodes.first)
    }

    @Test func inlineYAMLAndPasswordIsolation() throws {
        let input = """
        proxies:
          - {name: Inline, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, plugin: shadow-tls, plugin-opts: {host: www.example.com, password: outer, version: 3}, password: inner}
        """
        let node = try #require(SubscriptionParser().parse(data: Data(input.utf8)).nodes.first)
        #expect(node.password == "inner")
        #expect(node.shadowTLS?.password == "outer")
    }

    @Test func persistenceIdentityAndShare() throws {
        let node = try fixture()
        let decoded = try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(node))
        #expect(decoded == node)
        var changed = node
        changed.shadowTLS?.password = "changed"
        #expect(changed.canonicalKey != node.canonicalKey)
        changed.shadowTLS?.password = "outer;escape\\%2F&=+"
        changed.fingerprint = "chrome"
        let uri = ProxyNodeShareLinkGenerator().canonicalLink(for: changed)
        let reparsed = try #require(SubscriptionParser().parse(data: Data(uri.utf8)).nodes.first)
        #expect(reparsed.shadowTLS == changed.shadowTLS)
        #expect(reparsed.password == node.password)
        #expect(reparsed.fingerprint == changed.fingerprint)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        legacy.removeValue(forKey: "shadowTLS")
        legacy.removeValue(forKey: "plugin")
        #expect(try JSONDecoder().decode(ProxyNode.self, from: JSONSerialization.data(withJSONObject: legacy)).shadowTLS == nil)
    }

    @Test(arguments: ClientTarget.allCases)
    func exportCapabilityMatrix(_ target: ClientTarget) throws {
        let node = try fixture()
        let result = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: target)
        let supported: Set<ClientTarget> = [.clash, .clashApple, .clashVerge, .clashMac, .flClash,
            .mihomoParty, .clashMi, .surge, .surgeMac, .singBox, .hiddify, .loon, .egern, .shadowrocket]
        #expect(result.supportedNodeCount == (supported.contains(target) ? 1 : 0))
        #expect(result.skippedNodeCount == (supported.contains(target) ? 0 : 1))
        if supported.contains(target) {
            #expect(result.content.contains(Self.ssPassword))
            let encodedPassword = [.surge, .surgeMac].contains(target)
                ? Self.tlsPassword.replacingOccurrences(of: "%", with: "%25") : Self.tlsPassword
            #expect(result.content.contains(encodedPassword))
        }
    }

    @Test(arguments: [ClientTarget.clash, .clashApple, .surge, .surgeMac, .shadowrocket])
    func exportReimports(_ target: ClientTarget) throws {
        let node = try fixture()
        let result = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: target)
        let parsed = try #require(SubscriptionParser().parse(data: Data(result.content.utf8)).nodes.first)
        #expect(parsed.password == node.password)
        #expect(parsed.shadowTLS == node.shadowTLS)
    }

    @Test(arguments: [ClientTarget.singBox, .hiddify])
    func detourIsPrivateAndCollisionFree(_ target: ClientTarget) throws {
        var node = try fixture()
        node.name = "tower-shadowtls-0"
        let result = ConfigurationGenerator().generate(nodes: [node], preset: RulePreset.builtIns[0], target: target)
        let json = try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        let outbounds = try #require(json["outbounds"] as? [[String: Any]])
        let outer = try #require(outbounds.first { $0["type"] as? String == "shadowtls" })
        let inner = try #require(outbounds.first { $0["type"] as? String == "shadowsocks" })
        let tag = try #require(outer["tag"] as? String)
        #expect(inner["detour"] as? String == tag)
        #expect(inner["network"] as? String == "tcp")
        #expect(outer["password"] as? String == Self.tlsPassword)
        #expect(inner["password"] as? String == Self.ssPassword)
        #expect(Set(outbounds.compactMap { $0["tag"] as? String }).count == outbounds.count)
        for group in outbounds where group["outbounds"] != nil {
            #expect((group["outbounds"] as? [String])?.contains(tag) == false)
        }
    }

    @Test(arguments: ["version: 9", "version: invalid", "version: 0"])
    func rejectsInvalidVersions(_ replacement: String) {
        let input = Self.yaml.replacingOccurrences(of: "version: 3", with: replacement)
        let parsed = SubscriptionParser().parse(data: Data(input.utf8))
        #expect(parsed.nodes.isEmpty)
        #expect(parsed.rejectedLineCount == 1)
    }

    @Test func refusesLossyCombinations() throws {
        var node = try fixture()
        node.shadowTLS?.version = 1
        let generator = ConfigurationGenerator()
        #expect(generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: .surge).supportedNodeCount == 0)
        node.shadowTLS?.version = 3
        node.shadowTLS?.skipCertificateVerification = true
        #expect(generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: .clashApple).supportedNodeCount == 0)
        #expect(generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: .clash).supportedNodeCount == 1)
        let uot = Self.yaml.replacingOccurrences(of: "udp: false", with: "udp-over-tcp: true")
        #expect(SubscriptionParser().parse(data: Data(uot.utf8)).nodes.isEmpty)
    }

    @Test(arguments: [ClientTarget.singBox, .hiddify])
    func customSchemeIncludesDetour(_ target: ClientTarget) throws {
        let node = try fixture()
        let scheme = RuleScheme(id: "shadowtls", name: "ShadowTLS", summary: "", groups: [], rulesets: [
            .init(groupName: "DIRECT", resource: .inline("FINAL"))
        ])
        let result = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: target)
        let json = try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        let outbounds = try #require(json["outbounds"] as? [[String: Any]])
        let inner = try #require(outbounds.first { $0["type"] as? String == "shadowsocks" })
        let tag = try #require(inner["detour"] as? String)
        #expect(outbounds.contains { $0["type"] as? String == "shadowtls" && $0["tag"] as? String == tag })
    }

    @Test(arguments: ["host", "password", "version"])
    func rejectsMissingRequiredPluginFields(_ field: String) {
        let lines = Self.yaml.components(separatedBy: "\n").filter { !$0.hasPrefix("      " + field + ":") }
        #expect(SubscriptionParser().parse(data: Data(lines.joined(separator: "\n").utf8)).nodes.isEmpty)
    }
    @Test(arguments: [ClientTarget.loon, .egern])
    func additionalClientsPreserveLayers(_ target: ClientTarget) throws {
        let node = try fixture()
        let scheme = RuleScheme(id: "shadowtls", name: "ShadowTLS", summary: "", groups: [], rulesets: [
            .init(groupName: "DIRECT", resource: .inline("FINAL"))
        ])
        let result = ConfigurationGenerator().generate(nodes: [node], scheme: scheme, target: target)
        #expect(result.supportedNodeCount == 1)
        #expect(result.content.contains(Self.ssPassword))
        #expect(result.content.contains(Self.tlsPassword))
        if target == .loon {
            #expect(result.content.contains("shadow-tls-password=\(Self.tlsPassword),"))
            #expect(result.content.contains("shadow-tls-sni=www.example.com"))
            #expect(result.content.contains("shadow-tls-version=3"))
            #expect(result.content.contains("udp=false"))
            let nodes = ConfigurationGenerator().generateNodeSubscription(nodes: [node], target: target)
            #expect(nodes.supportedNodeCount == 1)
            #expect(nodes.content.contains("shadow-tls-version=3"))
        } else {
            #expect(result.content.contains("      shadow_tls:\n        password:"))
            #expect(result.content.contains("        sni: \"www.example.com\""))
            #expect(result.content.contains("udp_relay: false"))
        }
    }

    @Test(arguments: [ClientTarget.loon, .egern])
    func additionalClientsRejectUnrepresentableOptions(_ target: ClientTarget) throws {
        let generator = ConfigurationGenerator()
        func count(_ node: ProxyNode) -> Int {
            generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: target).supportedNodeCount
        }
        var node = try fixture()
        node.shadowTLS?.version = 1
        #expect(count(node) == 0)
        node.shadowTLS?.version = 2
        #expect(count(node) == (target == .loon ? 1 : 0))
        node = try fixture()
        node.shadowTLS?.skipCertificateVerification = true
        #expect(count(node) == 0)
        node = try fixture()
        node.fingerprint = "chrome"
        #expect(count(node) == 0)
        if target == .loon {
            for password in ["comma,password", "quote\"password", "line\nbreak", "white space"] {
                node = try fixture()
                node.shadowTLS?.password = password
                #expect(count(node) == 0)
            }
        }
    }

    @Test func shadowrocketFullAndNodesOnlyPreserveShadowTLS() throws {
        var node = try fixture()
        let generator = ConfigurationGenerator()
        let scheme = RuleScheme(id: "shadowtls", name: "ShadowTLS", summary: "", groups: [], rulesets: [
            .init(groupName: "DIRECT", resource: .inline("FINAL"))
        ])
        let full = generator.generate(nodes: [node], scheme: scheme, target: .shadowrocket)
        #expect(full.supportedNodeCount == 1)
        #expect(full.content.contains("plugin: shadow-tls"))
        #expect(full.content.contains("version: 3"))
        let parsed = try #require(SubscriptionParser().parse(data: Data(full.content.utf8)).nodes.first)
        #expect(parsed.shadowTLS == node.shadowTLS)
        #expect(parsed.password == node.password)
        let nodes = generator.generateNodeSubscription(nodes: [node], target: .shadowrocket)
        #expect(nodes.supportedNodeCount == 1)
        #expect(nodes.skippedNodeCount == 0)
        #expect(nodes.skippedNodes.isEmpty)
        #expect(nodes.content.hasPrefix("proxies:"))
        #expect(!nodes.content.contains("proxy-groups:"))
        #expect(!nodes.content.contains("rules:"))
        let imported = try #require(SubscriptionParser().parse(data: Data(nodes.content.utf8)).nodes.first)
        #expect(imported.shadowTLS == node.shadowTLS)
        #expect(imported.password == node.password)
        for version in [1, 2] {
            node.shadowTLS?.version = version
            #expect(generator.generate(nodes: [node], scheme: scheme, target: .shadowrocket).supportedNodeCount == 0)
        }
        node = try fixture()
        node.shadowTLS?.skipCertificateVerification = true
        #expect(generator.generate(nodes: [node], scheme: scheme, target: .shadowrocket).supportedNodeCount == 0)
        node = try fixture()
        node.fingerprint = "chrome"
        #expect(generator.generate(nodes: [node], scheme: scheme, target: .shadowrocket).supportedNodeCount == 0)
    }

    @Test(arguments: [ClientTarget.shadowrocket, .hiddify])
    func mixedNodeSubscriptionKeepsBothLayersAndOrdinaryNodes(_ target: ClientTarget) throws {
        let node = try fixture()
        var plain = try fixture()
        plain.name = "Ordinary SS"
        plain.plugin = nil
        plain.shadowTLS = nil
        let result = ConfigurationGenerator().generateNodeSubscription(nodes: [node, plain], target: target)
        #expect(result.supportedNodeCount == 2)
        #expect(result.skippedNodeCount == 0)
        #expect(result.ruleCount == 0)
        if target == .hiddify {
            let json = try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            #expect(Set(json.keys) == ["outbounds"])
            let outbounds = try #require(json["outbounds"] as? [[String: Any]])
            #expect(outbounds.count == 3)
            let helper = try #require(outbounds.first { $0["type"] as? String == "shadowtls" })
            let tag = try #require(helper["tag"] as? String)
            #expect(tag.contains("§hide§"))
            #expect(helper["password"] as? String == node.shadowTLS?.password)
            let tls = try #require(helper["tls"] as? [String: Any])
            #expect(tls["server_name"] as? String == node.shadowTLS?.host)
            let inner = try #require(outbounds.first { $0["detour"] as? String == tag })
            #expect(inner["password"] as? String == node.password)
            #expect(inner["network"] as? String == "tcp")
        } else {
            let parsed = SubscriptionParser().parse(data: Data(result.content.utf8)).nodes
            #expect(parsed.count == 2)
            #expect(parsed.first?.shadowTLS == node.shadowTLS)
        }
        let filtered = ConfigurationGenerator().generateNodeSubscription(
            nodes: [node, plain], target: target, excludedKinds: [.shadowsocks])
        #expect(filtered.supportedNodeCount == 0)
        #expect(filtered.skippedNodeCount == 2)
        // Lists without ShadowTLS retain their existing URI subscription format.
        let ordinary = ConfigurationGenerator().generateNodeSubscription(nodes: [plain], target: target)
        #expect(ordinary.supportedNodeCount == 1)
        #expect(!ordinary.content.contains("outbounds"))
        #expect(!ordinary.content.contains("proxies:"))
    }


    @Test(arguments: [1, 2, 3])
    func karingSkipsShadowTLSUntilClientConnectivityIsVerified(_ version: Int) throws {
        var node = try fixture()
        node.shadowTLS?.version = version
        let generator = ConfigurationGenerator()
        let scheme = RuleScheme(id: "karing-st", name: "Custom", summary: "", groups: [], rulesets: [
            .init(groupName: "DIRECT", resource: .inline("FINAL"))
        ])
        let results = [
            generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: .karing),
            generator.generate(nodes: [node], scheme: scheme, target: .karing),
            generator.generateNodeSubscription(nodes: [node], target: .karing)
        ]
        for result in results {
            #expect(result.supportedNodeCount == 0)
            #expect(result.skippedNodeCount == 1)
            #expect(result.skippedNodes.count == 1)
            #expect(!result.content.contains(Self.ssPassword))
            #expect(!result.content.contains(Self.tlsPassword))
        }
        node.shadowTLS = nil
        node.plugin = nil
        #expect(generator.generateNodeSubscription(nodes: [node], target: .karing).supportedNodeCount == 1)
    }

}

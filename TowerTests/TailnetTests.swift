import XCTest
@testable import Tower

/// Tailnets are written after generation, into both the built-in presets and
/// imported schemes. The shapes below were checked on Surge iOS, Stash 3.4,
/// Clash Mi and sing-box MT against a Headscale control server, and with
/// `mihomo -t` / `sing-box check`.
final class TailnetTests: XCTestCase {
    private let nodes = [
        ProxyNode(kind: .trojan, name: "A", server: "a.example.com", port: 443, password: "pw", rawURI: "")
    ]
    private let home = TailnetConnection(
        id: UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000")!,
        name: "家里",
        controlURLString: "https://hs.example.com",
        deviceName: "My iPhone",
        subnets: ["192.168.1.0/24", "fd00:1::/64"],
        magicDNSSuffix: "tail1234.ts.net"
    )
    private let writer = TailnetConfigurationWriter()

    private func full(_ target: ClientTarget, key: String? = "tskey-auth-test", connection: TailnetConnection? = nil) -> GeneratedConfiguration {
        let generated = ConfigurationGenerator().generate(nodes: nodes, preset: RulePreset.builtIns[0], target: target)
        return writer.apply([TailnetExport(connection: connection ?? home, authKey: key)], to: generated)
    }

    // MARK: - Validation

    func testNormalizesInput() throws {
        XCTAssertEqual(try TailnetConnection.normalizedSubnets("192.168.1.5/24, 10.0.0.1/8\nfd00:1::5/64 192.168.1.0/24"),
                       ["192.168.1.0/24", "10.0.0.0/8", "fd00:1::/64"])
        XCTAssertThrowsError(try TailnetConnection.normalizedSubnets("192.168.1.0"))
        XCTAssertThrowsError(try TailnetConnection.normalizedSubnets("192.168.1.0/33"))
        XCTAssertEqual(try TailnetConnection.normalizedControlURL(" https://hs.example.com:8443/ "), "https://hs.example.com:8443")
        XCTAssertNil(try TailnetConnection.normalizedControlURL(""))
        XCTAssertThrowsError(try TailnetConnection.normalizedControlURL("http://hs.example.com"))
        XCTAssertEqual(try TailnetConnection.normalizedMagicDNSSuffix(".Tail1234.TS.net."), "tail1234.ts.net")
        XCTAssertThrowsError(try TailnetConnection.normalizedMagicDNSSuffix("tail 1234.ts.net"))
        XCTAssertThrowsError(try TailnetConnection.normalizedMagicDNSSuffix("localhost"))
        XCTAssertEqual(try TailnetConnection.normalizedAuthKey(" hskey-auth-abc \n"), "hskey-auth-abc")
        XCTAssertThrowsError(try TailnetConnection.normalizedAuthKey("tskey auth"))
        XCTAssertThrowsError(try TailnetConnection.normalizedAuthKey("tskey,\"x"))
    }

    func testNamesAreSafeAndStable() {
        var connection = home
        connection.name = "家,里\n[x]=1"
        XCTAssertEqual(connection.policyName, "家，里 ［x］-1")
        connection.name = "  "
        XCTAssertEqual(connection.policyName, "Tailscale")
        XCTAssertEqual(home.hostname(for: "surge"), "my-iphone-surge")
        XCTAssertEqual(TailnetConnection(name: "x").hostname(for: "stash"), "tower-stash")
        XCTAssertEqual(home.stableSlug, "tower-tailnet-a1b2c3d4")
    }

    // MARK: - Surge

    func testSurgeGetsAPolicyTopRulesAndASection() throws {
        let output = full(.surge)
        let lines = output.content.components(separatedBy: "\n")
        let proxy = try XCTUnwrap(lines.firstIndex(of: "[Proxy]"))
        XCTAssertEqual(lines[proxy + 1], "家里 = tailscale, section-name=tower-tailnet-a1b2c3d4")
        let rule = try XCTUnwrap(lines.firstIndex(of: "[Rule]"))
        XCTAssertEqual(Array(lines[(rule + 1)...(rule + 5)]), [
            "DOMAIN-SUFFIX,tail1234.ts.net,家里",
            "IP-CIDR,100.64.0.0/10,家里,no-resolve",
            "IP-CIDR,192.168.1.0/24,家里,no-resolve",
            "IP-CIDR6,fd7a:115c:a1e0::/48,家里,no-resolve",
            "IP-CIDR6,fd00:1::/64,家里,no-resolve",
        ])
        XCTAssertTrue(output.content.hasSuffix("""
        [Tailscale tower-tailnet-a1b2c3d4]
        interactive-login = true
        control-url = https://hs.example.com
        hostname = my-iphone-surge

        """), output.content)
        XCTAssertTrue(output.diagnostics.isEmpty, output.diagnostics.joined())
        XCTAssertTrue(full(.surgeMac).content.contains("hostname = my-iphone-surge-mac"))
        // The tailnet is never a member of a policy group.
        XCTAssertEqual(output.content.components(separatedBy: "家里").count - 1, 6)
    }

    /// Surge keys its state to the auth key when one is present, so writing
    /// the key there would register a second machine beside the one the user
    /// already signed in. Every client without a working sign-in gets it.
    func testOnlySurgeSignsInWithoutTheKey() {
        for target in [ClientTarget.surge, .surgeMac] {
            XCTAssertFalse(full(target).content.contains("tskey-auth-test"), target.name)
        }
        XCTAssertTrue(full(.clash).content.contains("auth-key: \"tskey-auth-test\""))
        XCTAssertEqual(full(.clash, key: nil).diagnostics.count, 2)
        XCTAssertTrue(full(.surge).content.contains("interactive-login = true"))
        XCTAssertTrue(full(.surge).diagnostics.isEmpty)
        XCTAssertTrue(full(.clashMi).content.contains("auth-key: \"tskey-auth-test\""))
        XCTAssertTrue(full(.singBox).content.contains("\"auth_key\" : \"tskey-auth-test\""))
        XCTAssertTrue(full(.clashMi).diagnostics.isEmpty)
        XCTAssertEqual(full(.clashMi, key: nil).diagnostics.count, 1)
        XCTAssertEqual(full(.singBox, key: nil).diagnostics.count, 1)
    }

    /// Stash skips 100.64.0.0/10 and the private ranges by default, so only a
    /// MagicDNS name reaches the rules there.
    func testStashIsToldToUseMagicDNSNames() throws {
        let note = try XCTUnwrap(full(.clash).diagnostics.first)
        XCTAssertTrue(note.contains("tail1234.ts.net"), note)
        var connection = home
        connection.magicDNSSuffix = nil
        let missing = try XCTUnwrap(full(.clash, connection: connection).diagnostics.first)
        XCTAssertTrue(missing.contains("MagicDNS"), missing)
    }

    // MARK: - Stash and mihomo

    func testStashAndMihomoEntries() throws {
        let stash = full(.clash).content
        XCTAssertTrue(stash.contains("""
          - name: "家里"
            type: tailscale
            auth-key: "tskey-auth-test"
            control-url: "https://hs.example.com"
            hostname: "my-iphone-stash"
        """), stash)
        XCTAssertFalse(stash.contains("state-dir"))
        let lines = stash.components(separatedBy: "\n")
        let rules = try XCTUnwrap(lines.firstIndex(of: "rules:"))
        XCTAssertEqual(lines[rules + 1], "  - \"DOMAIN-SUFFIX,tail1234.ts.net,家里\"")
        XCTAssertEqual(lines[rules + 2], "  - \"IP-CIDR,100.64.0.0/10,家里,no-resolve\"")

        let mihomo = full(.clashMi).content
        XCTAssertTrue(mihomo.contains("""
            hostname: "my-iphone-clash-mi"
            state-dir: "tower-tailnet-a1b2c3d4"
            udp: true
            accept-routes: true
        """), mihomo)
        for target in [ClientTarget.clashApple, .clashVerge, .clashMac, .flClash, .mihomoParty] {
            XCTAssertTrue(full(target).content.contains("    type: tailscale"), target.name)
        }
    }

    func testReplacesAnEmptyProxyList() {
        let content = "proxies:\n\n  []\n\nproxy-groups:\n  - name: \"G\"\n    type: select\n    proxies: [DIRECT]\n\nrules:\n  - MATCH,G\n"
        let generated = GeneratedConfiguration(target: .clashMi, content: content, supportedNodeCount: 0, skippedNodeCount: 0, ruleCount: 1)
        let output = writer.apply([TailnetExport(connection: home, authKey: "k")], to: generated).content
        XCTAssertFalse(output.contains("  []"), output)
        XCTAssertTrue(output.contains("proxies:\n\n  - name: \"家里\"\n    type: tailscale"), output)
    }

    // MARK: - sing-box

    func testSingBoxEndpointDNSAndRouteOrder() throws {
        let output = full(.singBox)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.content.utf8)) as? [String: Any])
        let endpoint = try XCTUnwrap((root["endpoints"] as? [[String: Any]])?.first { $0["type"] as? String == "tailscale" })
        XCTAssertEqual(endpoint["tag"] as? String, "家里")
        XCTAssertEqual(endpoint["auth_key"] as? String, "tskey-auth-test")
        XCTAssertEqual(endpoint["control_url"] as? String, "https://hs.example.com")
        XCTAssertEqual(endpoint["state_directory"] as? String, "tower-tailnet-a1b2c3d4")
        XCTAssertEqual(endpoint["hostname"] as? String, "my-iphone-sing-box")
        XCTAssertEqual(endpoint["accept_routes"] as? Bool, true)

        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertTrue((dns["servers"] as? [[String: Any]])?.contains {
            $0["type"] as? String == "tailscale" && $0["endpoint"] as? String == "家里"
        } == true)
        XCTAssertEqual((dns["rules"] as? [[String: Any]])?.first?["domain_suffix"] as? [String], ["tail1234.ts.net"])

        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let index = try XCTUnwrap(rules.firstIndex { $0["outbound"] as? String == "家里" })
        XCTAssertTrue(rules[..<index].allSatisfy { ["sniff", "hijack-dns"].contains($0["action"] as? String) })
        XCTAssertEqual(rules[index]["ip_cidr"] as? [String],
                       ["100.64.0.0/10", "192.168.1.0/24", "fd7a:115c:a1e0::/48", "fd00:1::/64"])
    }

    func testSingBoxWithoutMagicDNSAddsNoResolver() throws {
        var connection = home
        connection.magicDNSSuffix = nil
        let output = full(.singBox, connection: connection)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.content.utf8)) as? [String: Any])
        let servers = ((root["dns"] as? [String: Any])?["servers"] as? [[String: Any]]) ?? []
        XCTAssertFalse(servers.contains { $0["type"] as? String == "tailscale" })
    }

    // MARK: - Skipping and names

    func testUnsupportedClientsExplainTheSkip() {
        for target in [ClientTarget.shadowrocket, .loon, .quanx, .egern, .hiddify, .karing] {
            let generated = ConfigurationGenerator().generate(nodes: nodes, preset: RulePreset.builtIns[0], target: target)
            let output = writer.apply([TailnetExport(connection: home, authKey: "k")], to: generated)
            XCTAssertEqual(output.content, generated.content, target.name)
            XCTAssertEqual(output.diagnostics.count, generated.diagnostics.count + 1, target.name)
            XCTAssertFalse(TailnetConfigurationWriter.supports(target))
        }
    }

    func testNodeListsAreLeftAlone() {
        let list = ConfigurationGenerator().generateNodeSubscription(nodes: nodes, target: .clashMi, profileName: "T")
        let output = writer.apply([TailnetExport(connection: home, authKey: "k")], to: list)
        XCTAssertEqual(output.content, list.content)
        XCTAssertEqual(output.diagnostics, list.diagnostics)
    }

    func testCollidingNamesGetASuffix() {
        let clash = [ProxyNode(kind: .trojan, name: "家里", server: "a.example.com", port: 443, password: "pw", rawURI: "")]
        let generated = ConfigurationGenerator().generate(nodes: clash, preset: RulePreset.builtIns[0], target: .surge)
        let output = writer.apply([TailnetExport(connection: home, authKey: "k")], to: generated).content
        XCTAssertTrue(output.contains("家里 2 = tailscale, section-name="), output)
        XCTAssertTrue(output.contains("IP-CIDR,100.64.0.0/10,家里 2,no-resolve"))
    }

    func testImportedSchemesGetTheSameRules() throws {
        let group = RuleSchemeGroup(name: "Proxy", kind: .select, members: [.nodePattern("^A$")])
        let scheme = RuleScheme(id: "s", name: "S", summary: "", groups: [group],
                                rulesets: [.init(groupName: "Proxy", resource: .inline("FINAL"))], isBundled: false)
        for target in [ClientTarget.surge, .clash, .clashMi, .singBox] {
            let generated = ConfigurationGenerator().generate(nodes: nodes, scheme: scheme, target: target)
            let output = writer.apply([TailnetExport(connection: home, authKey: "k")], to: generated)
            XCTAssertTrue(output.content.contains("100.64.0.0/10"), "\(target.name): \(output.content)")
            XCTAssertTrue(output.content.contains("tailscale"), target.name)
        }
    }

    /// Writes complete profiles for the local cores when an output directory
    /// is given; skipped otherwise. Used with a Headscale key to run them live.
    func testWritesProfilesForLocalCores() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["TOWER_TAILNET_OUT"] else { throw XCTSkip("no output directory") }
        let connection = TailnetConnection(
            id: home.id, name: "家里", controlURLString: environment["TOWER_TAILNET_CONTROL"],
            deviceName: "tower-core", subnets: [environment["TOWER_TAILNET_SUBNET"] ?? "192.168.1.0/24"], magicDNSSuffix: environment["TOWER_TAILNET_SUFFIX"]
        )
        // Real, reachable nodes let a client on a device reach the control
        // server through the profile's own rules; the fixture node cannot.
        let profileNodes = try environment["TOWER_TAILNET_NODES"].map {
            SubscriptionParser().parse(data: try Data(contentsOf: URL(fileURLWithPath: $0))).nodes
        } ?? nodes
        let targets: [(ClientTarget, String)] = [(.clashMi, "mihomo.yaml"), (.clash, "stash.yaml"), (.singBox, "sing-box.json"),
                                                 (.surge, "surge.conf"), (.surgeMac, "surge-mac.conf"), (.shadowrocket, "shadowrocket.yaml")]
        for (target, file) in targets {
            let generated = ConfigurationGenerator().generate(nodes: profileNodes, preset: RulePreset.builtIns[0], target: target)
            let output = writer.apply([TailnetExport(connection: connection, authKey: environment["TOWER_TAILNET_KEY"])], to: generated)
            try output.content.write(toFile: directory + "/" + file, atomically: true, encoding: .utf8)
            try output.diagnostics.joined(separator: "\n").write(toFile: directory + "/" + file + ".notes.txt", atomically: true, encoding: .utf8)
        }
    }

    // MARK: - App model

    @MainActor
    private func makeModel(keys: InMemoryTailnetAuthKeyStore, url: URL) -> AppModel {
        let model = AppModel(persistence: PersistenceStore(fileURL: url), arguments: [], tailnetAuthKeys: keys)
        return model
    }

    @MainActor
    func testKeysStayOutOfTheSnapshotAndFollowDeletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tower-tailnet-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let keys = InMemoryTailnetAuthKeyStore()
        let model = makeModel(keys: keys, url: url)
        model.nodes = nodes
        try model.saveTailnet(home, authKey: .set("tskey-auth-secret"))
        XCTAssertTrue(model.hasTailnetAuthKey(home.id))
        XCTAssertTrue(model.configuration(target: .clashMi, contentMode: .fullConfiguration).content.contains("auth-key: \"tskey-auth-secret\""))
        XCTAssertEqual(model.tailnetAuthKey(for: home.id), "tskey-auth-secret")

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("tail1234.ts.net"))
        XCTAssertFalse(saved.contains("tskey-auth-secret"))

        // Reloading keeps the key; changing it rebuilds the cached profile.
        let reloaded = makeModel(keys: keys, url: url)
        XCTAssertTrue(reloaded.hasTailnetAuthKey(home.id))
        try reloaded.saveTailnet(home, authKey: .remove)
        XCTAssertFalse(reloaded.configuration(target: .clashMi, contentMode: .fullConfiguration).content.contains("auth-key"))

        reloaded.setTailnetEnabled(home.id, false)
        XCTAssertFalse(reloaded.configuration(target: .surge, contentMode: .fullConfiguration).content.contains("tailscale"))

        try reloaded.saveTailnet(home, authKey: .set("tskey-auth-second"))
        let mihomo = reloaded.configuration(target: .clashMi, contentMode: .fullConfiguration).content
        let preview = reloaded.maskingTailnetAuthKeys(in: mihomo)
        XCTAssertFalse(preview.contains("tskey-auth-second"))
        XCTAssertTrue(preview.contains("auth-key: \"•••••••••••••••••\""))
        XCTAssertEqual(preview.count, mihomo.count)
        reloaded.deleteTailnet(home.id)
        XCTAssertNil(keys.authKey(for: home.id))
        XCTAssertTrue(reloaded.tailnets.isEmpty)
    }

    @MainActor
    func testOrphanedKeysAreRemovedOnLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tower-tailnet-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let orphan = UUID()
        let keys = InMemoryTailnetAuthKeyStore([orphan: "stale"])
        let model = makeModel(keys: keys, url: url)
        try model.saveTailnet(home, authKey: .set("k"))
        _ = makeModel(keys: keys, url: url)
        XCTAssertNil(keys.authKey(for: orphan))
        XCTAssertEqual(keys.authKey(for: home.id), "k")
    }
}

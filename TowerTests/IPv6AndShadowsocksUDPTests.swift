import XCTest
@testable import Tower

final class IPv6AndShadowsocksUDPTests: XCTestCase {
    func testIPv6CanonicalLinksRoundTripWithoutFallingBackToSyntheticURI() throws {
        let parser = SubscriptionParser()
        for kind: ProxyKind in [.shadowsocks, .trojan, .vless, .hysteria2, .tuic, .anytls, .socks5, .http] {
            let proxy = ProxyNode(kind: kind, name: "IPv6", server: "2001:db8::123", port: 443,
                                  cipher: "aes-256-gcm", password: "password",
                                  uuid: "11111111-2222-4333-8444-555555555555", rawURI: "clash://local/fixture")
            let link = ProxyNodeShareLinkGenerator().canonicalLink(for: proxy)
            let restored = try XCTUnwrap(parser.parseURI(link), "\(kind): \(link)")
            XCTAssertEqual(restored.server, proxy.server, "\(kind)")
            XCTAssertEqual(restored.port, proxy.port)
        }
    }

    func testIPv6ShadowsocksRHandlesColonsInsideTheHost() throws {
        for host in ["2001:db8::123", "[2001:db8::123]"] {
            let payload = "\(host):8388:origin:aes-256-cfb:plain:cGFzc3dvcmQ/?remarks=U1NS"
            let parsed = try XCTUnwrap(SubscriptionParser().parseURI("ssr://" + Data(payload.utf8).base64EncodedString()))
            XCTAssertEqual(parsed.server, "2001:db8::123")
            XCTAssertEqual(parsed.password, "password")
            let link = ProxyNodeShareLinkGenerator().canonicalLink(for: parsed)
            XCTAssertEqual(SubscriptionParser().parseURI(link)?.server, parsed.server)
        }
    }

    func testWireGuardIPv6CanonicalLink() throws {
        let proxy = ProxyNode(kind: .wireguard, name: "WG", server: "2001:db8::123", port: 51820,
                              wireGuardPrivateKey: String(repeating: "A", count: 43) + "=",
                              wireGuardPublicKey: String(repeating: "B", count: 43) + "=",
                              wireGuardIPv4: "10.0.0.2/32", rawURI: "clash://local/fixture")
        let restored = try XCTUnwrap(SubscriptionParser().parseURI(ProxyNodeShareLinkGenerator().canonicalLink(for: proxy)))
        XCTAssertEqual(restored.server, proxy.server)
    }

    func testUDPPreferencesSurvivePersistenceSharingAndIdentity() throws {
        let parser = SubscriptionParser()
        var keys = Set<String>()
        for value in ["true", "false"] {
            let node = try XCTUnwrap(parser.parseURI("ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@host.example:8388?udp=\(value)#SS"))
            XCTAssertEqual(node.udpRelayEnabled, value == "true")
            let restored = try JSONDecoder().decode(ProxyNode.self, from: JSONEncoder().encode(node))
            XCTAssertEqual(restored.udpRelayEnabled, node.udpRelayEnabled)
            let link = ProxyNodeShareLinkGenerator().canonicalLink(for: restored)
            XCTAssertEqual(parser.parseURI(link)?.udpRelayEnabled, node.udpRelayEnabled)
            keys.insert(node.canonicalKey)
        }
        XCTAssertEqual(keys.count, 2)
        let plain = try XCTUnwrap(parser.parseURI("ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@host.example:8388#SS"))
        XCTAssertNil(plain.udpRelayEnabled)
        let oldData = try JSONEncoder().encode(plain)
        XCTAssertNil(try JSONDecoder().decode(ProxyNode.self, from: oldData).udpRelayEnabled)
    }

    func testIPv6SSExportsAcrossAllClientsAndBothModes() throws {
        let node = try XCTUnwrap(SubscriptionParser().parseURI("ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@[2001:db8::123]:8388?udp-relay=true#SS"))
        for target in ClientTarget.allCases {
            let generator = ConfigurationGenerator()
            let outputs = target.supportedContentModes.map { mode in
                mode == .nodesOnly
                    ? generator.generateNodeSubscription(nodes: [node], target: target, profileName: "IPv6")
                    : generator.generate(nodes: [node], preset: RulePreset.builtIns[0], target: target)
            }
            for output in outputs {
                XCTAssertEqual(output.supportedNodeCount, 1, "\(target)")
                let content = Data(base64Encoded: output.content).flatMap { String(data: $0, encoding: .utf8) } ?? output.content
                XCTAssertTrue(content.contains("2001:db8::123"), "\(target)")
                XCTAssertFalse(content.contains("clash://local/"))
            }
        }
    }

    func testSSUDPFalseSurvivesEveryStructuredTarget() throws {
        let sources = [
            "proxies:\n  - {name: SS, type: ss, server: '2001:db8::123', port: 8388, cipher: aes-256-gcm, password: password, udp: false}",
            "[Proxy]\nSS = ss, 2001:db8::123, 8388, encrypt-method=aes-256-gcm, password=password, udp-relay=false",
            "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@[2001:db8::123]:8388?udp-relay=false#SS"
        ]
        for source in sources {
            let proxy = try XCTUnwrap(SubscriptionParser().parse(data: Data(source.utf8)).nodes.first)
            let expected: [(ClientTarget, String)] = [
                (.surge, "udp-relay=false"), (.surgeMac, "udp-relay=false"), (.quanx, "udp-relay=false"),
                (.loon, "udp=false"), (.clash, "udp: false"), (.clashApple, "udp: false"),
                (.shadowrocket, "udp: false"), (.egern, "udp_relay: false"),
                (.clashMi, "udp: false"), (.clashVerge, "udp: false"), (.clashMac, "udp: false"),
                (.flClash, "udp: false"), (.mihomoParty, "udp: false"), (.karing, "udp: false")
            ]
            for (target, field) in expected {
                let result = ConfigurationGenerator().generate(nodes: [proxy], preset: RulePreset.builtIns[0], target: target)
                XCTAssertTrue(result.content.contains(field), "\(target): missing \(field)")
            }
            for target: ClientTarget in [.singBox, .hiddify] {
                let result = ConfigurationGenerator().generate(nodes: [proxy], preset: RulePreset.builtIns[0], target: target)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
                let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
                let ss = try XCTUnwrap(outbounds.first { $0["type"] as? String == "shadowsocks" })
                XCTAssertEqual(ss["network"] as? String, "tcp")
            }
        }
    }
}

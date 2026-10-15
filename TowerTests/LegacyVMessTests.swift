import XCTest
@testable import Tower

/// Some clients, Shadowrocket among them, do not use the base64-JSON form of a
/// vmess link. They base64 only `method:uuid@host:port` and put the options in
/// a query string, which the JSON parser rejected outright.
final class LegacyVMessTests: XCTestCase {
    private let parser = SubscriptionParser()

    /// base64 of `auto:5d1c3d8f-77b7-45c7-98c7-6fa54d37766e@203.0.113.9:53837`
    private let endpoint = "YXV0bzo1ZDFjM2Q4Zi03N2I3LTQ1YzctOThjNy02ZmE1NGQzNzc2NmVAMjAzLjAuMTEzLjk6NTM4Mzc"

    func testBatchJSONWebSocketHostsSurvivePersistence() throws {
        let hosts = ["cdn.example.com", #"{"Host":"cdn.example.com"}"#,
                     #"{"headers":{"host":"cdn.example.com"}}"#]
        let links = hosts.enumerated().map { index, host in
            let encoded = host.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            return "vmess://\(endpoint)?remarks=Fixture-\(index)&obfs=websocket&tls=1&peer=tls.example.com&obfsParam=\(encoded)&path=%2Fws"
        }
        let result = try LocalNodeImporter().parse(links.joined(separator: "\n"))
        XCTAssertEqual(result.nodes.count, 3)
        let saved = try JSONEncoder().encode(result.nodes)
        let restored = try JSONDecoder().decode([ProxyNode].self, from: saved)
        for node in restored {
            XCTAssertEqual(node.hostHeader, "cdn.example.com")
            XCTAssertEqual(node.sni, "tls.example.com")
            XCTAssertEqual(node.path, "/ws")
            XCTAssertTrue(node.tls)
        }
    }

    func testShadowrocketReturnedThreeNodeBatch() throws {
        let text = """
        vmess://YXV0bzoxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTVAMTkyLjAuMi4xOjQ0Mw?path=/ws&remarks=Tower-WS-TLS-1&obfsParam=cdn.example.com&obfs=websocket&tls=1&peer=tls.example.com&udp=1&alterId=0

        vmess://YXV0bzoxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTVAMTkyLjAuMi4yOjQ0Mw?path=/ws&remarks=Tower-WS-TLS-2&obfsParam=edge.example.net&obfs=websocket&tls=1&peer=tls.example.com&udp=1&alterId=0

        vmess://YXV0bzoxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTVAMTkyLjAuMi4zOjQ0Mw?path=/ws&remarks=Tower-WS-TLS-3&obfsParam=ws.example.org&obfs=websocket&tls=1&peer=tls.example.com&udp=1&alterId=0
        """
        let result = try LocalNodeImporter().parse(text)
        XCTAssertEqual(result.rejectedLineCount, 0)
        XCTAssertEqual(result.nodes.count, 3)
        let restored = try JSONDecoder().decode([ProxyNode].self, from: JSONEncoder().encode(result.nodes))
        XCTAssertEqual(restored.map(\.hostHeader), ["cdn.example.com", "edge.example.net", "ws.example.org"])
        for (index, node) in restored.enumerated() {
            XCTAssertEqual(node.name, "Tower-WS-TLS-\(index + 1)")
            XCTAssertEqual(node.server, "192.0.2.\(index + 1)")
            XCTAssertEqual(node.port, 443)
            XCTAssertEqual(node.uuid, "11111111-2222-3333-4444-555555555555")
            XCTAssertEqual(node.cipher, "auto")
            XCTAssertEqual(node.transport, "ws")
            XCTAssertEqual(node.path, "/ws")
            XCTAssertEqual(node.sni, "tls.example.com")
            XCTAssertTrue(node.tls)
            XCTAssertEqual(node.alterID, 0)
            let shared = ProxyNodeShareLinkGenerator().canonicalLink(for: node)
            XCTAssertEqual(try XCTUnwrap(parser.parseURI(shared)).hostHeader, node.hostHeader)
        }
    }

    func testShadowrocketJSONSingleArrayAndConcatenatedBatch() throws {
        let hosts = ["cdn.example.com", "edge.example.net", "ws.example.org"]
        let objects: [[String: Any]] = hosts.enumerated().map { index, host in
            ["host": "192.0.2.\(index + 1)", "port": "443", "type": "Vmess",
             "title": "Tower-WS-TLS-\(index + 1)", "obfsParam": host,
             "obfs": "websocket", "tls": true, "peer": "tls.example.com",
             "path": "/ws", "method": "auto", "alterId": "0", "udp": 1,
             "uuid": "2FA60655-45D1-4731-9F3A-624AE5644ABE",
             "password": "11111111-2222-3333-4444-555555555555",
             "cert": "", "hpkp": "", "chain": ""]
        }
        func encode(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]), as: UTF8.self)
        }
        let batch = try objects.map(encode).joined(separator: "\n\n")
        for input in [try encode(objects), batch] {
            let result = try LocalNodeImporter().parse(input)
            XCTAssertEqual(result.nodes.count, 3)
            XCTAssertEqual(result.rejectedLineCount, 0)
            XCTAssertEqual(SourceInputDetector().detect(input), .nodeBatch(count: 3))
            let saved = try JSONDecoder().decode([ProxyNode].self, from: JSONEncoder().encode(result.nodes))
            XCTAssertEqual(saved.map(\.hostHeader), hosts)
            for node in saved {
                XCTAssertEqual(node.uuid, "11111111-2222-3333-4444-555555555555")
                XCTAssertEqual(node.path, "/ws")
                XCTAssertEqual(node.sni, "tls.example.com")
                XCTAssertTrue(node.tls)
            }
        }
        let compact = String(decoding: try JSONSerialization.data(withJSONObject: objects[0]), as: UTF8.self)
        XCTAssertEqual(SourceInputDetector().detect(compact), .node(.vmess))
        XCTAssertEqual(try LocalNodeImporter().parse(compact).nodes.first?.hostHeader, hosts[0])
    }

    func testShadowrocketJSONEscapesHeadersAndUnsupportedRecords() throws {
        let record: [String: Any] = [
            "type": "Vmess", "host": "192.0.2.1", "port": 443,
            "title": "Node } { \"quoted\"", "password": "test-uuid", "tls": true,
            "obfs": "websocket", "obfsParam": #"{"Host":"cdn.example.com"}"#, "path": #"\/ws"#
        ]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        let result = parser.parse(data: Data((encoded + "\n" + encoded).utf8))
        XCTAssertEqual(result.nodes.count, 1) // Same node is deduplicated.
        XCTAssertEqual(result.rejectedLineCount, 0)
        XCTAssertEqual(result.nodes.first?.hostHeader, "cdn.example.com")
        XCTAssertEqual(result.nodes.first?.path, "/ws")
        var unsupported = record
        unsupported["chain"] = "another-node"
        let mixed = try JSONSerialization.data(withJSONObject: [record, unsupported, ["type": "unknown"]])
        let parsed = parser.parse(data: mixed)
        XCTAssertEqual(parsed.nodes.count, 1)
        XCTAssertEqual(parsed.rejectedLineCount, 2)
        XCTAssertTrue(parser.parse(data: Data((encoded + "\n{bad").utf8)).nodes.isEmpty)
        let node = try XCTUnwrap(result.nodes.first)
        for target in ClientTarget.allCases {
            let output = ConfigurationGenerator().generateNodeSubscription(nodes: [node], target: target)
            if output.supportedNodeCount > 0 {
                XCTAssertFalse(output.content.contains(#"{\"Host\""#), "\(target)")
            }
        }
    }

    func testParsesEndpointOnlyForm() throws {
        let node = try XCTUnwrap(parser.parseURI("vmess://\(endpoint)"))

        XCTAssertEqual(node.kind, .vmess)
        XCTAssertEqual(node.server, "203.0.113.9")
        XCTAssertEqual(node.port, 53837)
        XCTAssertEqual(node.uuid, "5d1c3d8f-77b7-45c7-98c7-6fa54d37766e")
        XCTAssertEqual(node.cipher, "auto")
    }

    func testRemarksBecomeTheNodeName() throws {
        let node = try XCTUnwrap(
            parser.parseURI("vmess://\(endpoint)?remarks=%E6%97%A5%E6%9C%AC%E9%98%BF%E9%87%8C%E4%BA%91&udp=1&alterId=0")
        )

        XCTAssertEqual(node.name, "日本阿里云")
        XCTAssertEqual(node.alterID, 0)
    }

    func testFallsBackToTheHostWhenUnnamed() throws {
        let node = try XCTUnwrap(parser.parseURI("vmess://\(endpoint)"))

        XCTAssertEqual(node.name, "203.0.113.9")
    }

    func testWebsocketObfsBecomesTheTransport() throws {
        let node = try XCTUnwrap(
            parser.parseURI("vmess://\(endpoint)?obfs=websocket&path=%2Fgw&obfsParam=a.example.com&tls=1&peer=a.example.com")
        )

        // This dialect names the transport obfs, not net.
        XCTAssertEqual(node.transport, "ws")
        XCTAssertEqual(node.path, "/gw")
        XCTAssertEqual(node.hostHeader, "a.example.com")
        XCTAssertEqual(node.sni, "a.example.com")
        XCTAssertTrue(node.tls)
    }

    func testPlainTransportStaysUnset() throws {
        let node = try XCTUnwrap(parser.parseURI("vmess://\(endpoint)?obfs=none"))

        XCTAssertNil(node.transport)
        XCTAssertFalse(node.tls)
    }

    func testUUIDWithoutMethodStillParses() throws {
        // base64 of `5d1c3d8f-77b7-45c7-98c7-6fa54d37766e@203.0.113.9:443`
        let bare = "NWQxYzNkOGYtNzdiNy00NWM3LTk4YzctNmZhNTRkMzc3NjZlQDIwMy4wLjExMy45OjQ0Mw"
        let node = try XCTUnwrap(parser.parseURI("vmess://\(bare)"))

        XCTAssertEqual(node.uuid, "5d1c3d8f-77b7-45c7-98c7-6fa54d37766e")
        XCTAssertEqual(node.cipher, "auto")
    }

    // MARK: - The standard form must keep working

    func testBase64JSONFormIsUnaffected() throws {
        let json = #"{"v":"2","ps":"JSON 节点","add":"198.51.100.4","port":"443","id":"5d1c3d8f-77b7-45c7-98c7-6fa54d37766e","aid":"0","net":"ws","tls":"tls"}"#
        let link = "vmess://" + Data(json.utf8).base64EncodedString()

        let node = try XCTUnwrap(parser.parseURI(link))

        XCTAssertEqual(node.name, "JSON 节点")
        XCTAssertEqual(node.server, "198.51.100.4")
        XCTAssertEqual(node.transport, "ws")
        XCTAssertTrue(node.tls)
    }

    func testBase64JSONNormalizesWebSocketTransportAliases() throws {
        let variants: [[String: Any]] = [
            ["net": "websocket"],
            ["network": "ws"],
            ["type": "websocket"]
        ]

        for variant in variants {
            var object: [String: Any] = [
                "v": "2",
                "ps": "WS 节点",
                "add": "198.51.100.8",
                "port": "443",
                "id": "5d1c3d8f-77b7-45c7-98c7-6fa54d37766e",
                "aid": "0",
                "host": "edge.example.com",
                "path": "/gateway",
                "sni": "tls.example.com",
                "tls": "tls"
            ]
            object.merge(variant) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: object)
            let link = "vmess://" + data.base64EncodedString()

            let node = try XCTUnwrap(parser.parseURI(link), "未解析 \(variant)")

            XCTAssertEqual(node.transport, "ws", "未归一化 \(variant)")
            XCTAssertEqual(node.hostHeader, "edge.example.com")
            XCTAssertEqual(node.path, "/gateway")
            XCTAssertEqual(node.sni, "tls.example.com")
            XCTAssertTrue(node.tls)

            for target in ClientTarget.allCases
                where target.supportsFullConfigurationExport && target.supports(.vmess) {
                let content = ConfigurationGenerator().generate(
                    nodes: [node],
                    preset: RulePreset.builtIns[0],
                    target: target
                ).content
                XCTAssertTrue(content.contains("edge.example.com"), "\(target.name) 丢失 WebSocket Host")
                XCTAssertTrue(content.contains("/gateway"), "\(target.name) 丢失 WebSocket Path")
                XCTAssertFalse(content.contains("network: \"websocket\""), "\(target.name) 写出了未归一化传输")
            }
        }
    }

    func testLegacyWebSocketOptionsAreCaseInsensitive() throws {
        let node = try XCTUnwrap(
            parser.parseURI("vmess://\(endpoint)?OBFS=WebSocket&PATH=%2Fgw&obfsparam=edge.example.com&TLS=1&PEER=tls.example.com")
        )

        XCTAssertEqual(node.transport, "ws")
        XCTAssertEqual(node.path, "/gw")
        XCTAssertEqual(node.hostHeader, "edge.example.com")
        XCTAssertEqual(node.sni, "tls.example.com")
        XCTAssertTrue(node.tls)
    }

    func testGarbageStillFails() {
        XCTAssertNil(parser.parseURI("vmess://not-valid-base64-at-all!!!"))
    }

    // MARK: - Add panel

    func testDetectorAcceptsTheLegacyForm() {
        XCTAssertEqual(
            SourceInputDetector().detect("vmess://\(endpoint)?remarks=x"),
            .node(.vmess)
        )
    }

    func testGeneratesForEveryTargetThatSupportsVMess() throws {
        let node = try XCTUnwrap(
            parser.parseURI("vmess://\(endpoint)?obfs=websocket&path=%2Fgw&tls=1")
        )

        for target in ClientTarget.allCases
            where target.supportsFullConfigurationExport && target.supports(.vmess) {
            let content = ConfigurationGenerator().generate(
                nodes: [node],
                preset: RulePreset.builtIns[0],
                target: target
            ).content
            XCTAssertTrue(content.contains("203.0.113.9"), "\(target.name) 没写出节点")
        }
    }
}

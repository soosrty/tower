import XCTest
@testable import Tower

final class AnywhereTests: XCTestCase {
    func testNodesOnlyCapabilityAndOrder() throws {
        let target = try XCTUnwrap(ClientTarget(rawValue: "anywhere"))
        XCTAssertEqual(target.name, "Anywhere")
        XCTAssertEqual(target.supportedContentModes, [.nodesOnly])
        XCTAssertTrue(target.supportsDirectImport(mode: .nodesOnly))
        XCTAssertFalse(target.supportsEmbeddedRemoteSubscriptions)
        let order = ClientTargetOrder.defaultOrder
        XCTAssertEqual(order[try XCTUnwrap(order.firstIndex(of: .clashApple)) + 1], target)
        let old = order.filter { $0 != target }
        let migrated = ClientTargetOrder.normalized(rawValues: old.map(\.rawValue))
        XCTAssertEqual(migrated, order)
    }

    func testImportPreservesInnerURLVerbatim() throws {
        let target = try XCTUnwrap(ClientTarget(rawValue: "anywhere"))
        let source = try XCTUnwrap(URL(string: "http://127.0.0.1:8765/nodes.txt?token=a%26b&content=nodesOnly"))
        let url = try ClientImportURLBuilder.make(target: target, configurationURL: source, contentMode: .nodesOnly)
        let suffix = String(url.absoluteString.dropFirst("anywhere://add-proxy?link=".count))
        XCTAssertEqual(suffix.removingPercentEncoding, source.absoluteString)
        XCTAssertThrowsError(try ClientImportURLBuilder.make(target: target, configurationURL: source))
    }
    func testIPv6AndAnyTLSParameters() throws {
        let target = try XCTUnwrap(ClientTarget(rawValue: "anywhere"))
        let node = ProxyNode(kind: .anytls, name: "A & B", server: "2001:db8::1", port: 443,
                             password: "p@ss:word", tls: true, sni: "example.com",
                             idleSessionCheckInterval: 17, idleSessionTimeout: 21, minIdleSession: 3, rawURI: "")
        let result = ConfigurationGenerator().generateNodeSubscription(nodes: [node], target: target)
        XCTAssertEqual(result.supportedNodeCount, 1)
        XCTAssertEqual(result.ruleCount, 0)
        XCTAssertTrue(result.content.contains("@[2001:db8::1]:443"))
        XCTAssertTrue(result.content.contains("ici=17"))
        XCTAssertTrue(result.content.contains("it=21"))
        XCTAssertTrue(result.content.contains("mis=3"))
        XCTAssertFalse(result.content.contains("idle-session"))
    }

    func testRejectsUnrepresentableNodesInsteadOfLosingSettings() throws {
        let target = try XCTUnwrap(ClientTarget(rawValue: "anywhere"))
        let base = ProxyNode(kind: .trojan, name: "Test", server: "example.com", port: 443, password: "secret", tls: true, rawURI: "")
        var pin = base; pin.certificateFingerprint = String(repeating: "ab", count: 32)
        var insecure = base; insecure.skipCertificateVerification = true
        var ws = base; ws.transport = "ws"
        var ss = base; ss.kind = .shadowsocks; ss.tls = false; ss.cipher = "aes-128-gcm"
        var udpOff = ss; udpOff.udpRelayEnabled = false
        var plugin = ss; plugin.plugin = "obfs-local"
        var vmess = base; vmess.kind = .vmess
        let result = ConfigurationGenerator().generateNodeSubscription(nodes: [base, ss, pin, insecure, ws, udpOff, plugin, vmess], target: target)
        XCTAssertEqual(result.supportedNodeCount, 2)
        XCTAssertEqual(result.skippedNodeCount, 6)
    }

    /// Fingerprints follow Anywhere's own Clash importer, and each skip says
    /// which setting Anywhere cannot keep.
    func testFingerprintsAndSpecificSkipReasons() throws {
        let target = try XCTUnwrap(ClientTarget(rawValue: "anywhere"))
        // Separate nodes: skip details are keyed by node identity.
        func node(_ name: String) -> ProxyNode {
            ProxyNode(kind: .anytls, name: name, server: "example.com", port: 443, password: "pw", tls: true, sni: "example.com", rawURI: "")
        }
        var chrome = node("chrome"); chrome.fingerprint = "chrome"
        var ios = node("ios"); ios.fingerprint = "ios"
        var random = node("random"); random.fingerprint = "random"
        var qq = node("qq"); qq.fingerprint = "qq"
        var insecure = node("insecure"); insecure.skipCertificateVerification = true
        let result = ConfigurationGenerator().generateNodeSubscription(nodes: [chrome, ios, random, qq, insecure], target: target)
        XCTAssertEqual(result.supportedNodeCount, 3)
        XCTAssertTrue(result.content.contains("fp=chrome_133"), result.content)
        XCTAssertTrue(result.content.contains("fp=chrome_120"), result.content)
        XCTAssertFalse(result.content.contains("fp=random"), result.content)
        let reasons = Dictionary(uniqueKeysWithValues: result.skippedNodes.map { ($0.name, $0.reason) })
        XCTAssertTrue(reasons["qq"]?.contains("qq") == true, "\(reasons)")
        XCTAssertTrue(reasons["insecure"]?.contains("跳过证书校验") == true, "\(reasons)")
    }
}

import XCTest
@testable import Tower

final class CertificatePinExportTests: XCTestCase {
    private let pin = String(repeating: "AB", count: 32)

    private func node(_ kind: ProxyKind, tls: Bool = true) -> ProxyNode {
        ProxyNode(kind: kind, name: "Pinned", server: "pin.example.com", port: 443,
                  cipher: "auto", password: "password", uuid: "11111111-2222-3333-4444-555555555555",
                  tls: tls, sni: "pin.example.com", certificateFingerprint: pin, rawURI: "")
    }

    func testStashUsesItsOwnCertificatePinFieldInBothModes() {
        for kind: ProxyKind in [.trojan, .vmess, .hysteria2, .tuic, .http, .socks5] {
            let proxy = node(kind)
            let generator = ConfigurationGenerator()
            for result in [generator.generate(nodes: [proxy], preset: RulePreset.builtIns[0], target: .clash),
                           generator.generateNodeSubscription(nodes: [proxy], target: .clash)] {
                guard result.supportedNodeCount > 0 else { continue }
                XCTAssertTrue(result.content.contains("    server-cert-fingerprint: \"\(pin)\""), "\(kind)")
                XCTAssertFalse(result.content.contains("\n    fingerprint:"), "\(kind)")
                XCTAssertFalse(result.content.contains("skip-cert-verify: true"))
            }
        }
    }

    func testStashCertificatePinImportsAndConvertsToOtherDialects() throws {
        let source = "proxies:\n  - {name: Stash, type: trojan, server: example.com, port: 443, password: password, server-cert-fingerprint: \"\(pin)\"}"
        let proxy = try XCTUnwrap(SubscriptionParser().parse(data: Data(source.utf8)).nodes.first)
        XCTAssertEqual(proxy.certificateFingerprint, pin)
        let output = ConfigurationGenerator().generate(nodes: [proxy], preset: RulePreset.builtIns[0], target: .clashMi)
        XCTAssertTrue(output.content.contains("    fingerprint: \"\(pin)\""))
        XCTAssertFalse(output.content.contains("server-cert-fingerprint:"))
    }

    func testSurgePinsEverySupportedTLSProtocolInBothExportModes() {
        for target: ClientTarget in [.surge, .surgeMac] {
            for kind: ProxyKind in [.trojan, .hysteria2, .tuic, .anytls, .vmess, .http, .socks5] {
                for separator in ["", ":", "-"] {
                    var proxy = node(kind)
                    proxy.certificateFingerprint = Array(repeating: "AB", count: 32).joined(separator: separator)
                    let generator = ConfigurationGenerator()
                    let outputs = [generator.generate(nodes: [proxy], preset: RulePreset.builtIns[0], target: target),
                                   generator.generateNodeSubscription(nodes: [proxy], target: target, profileName: "Pins")]
                    for output in outputs {
                        XCTAssertEqual(output.supportedNodeCount, 1, "\(target) \(kind)")
                        XCTAssertEqual(output.content.components(separatedBy: "server-cert-fingerprint-sha256=\(pin)").count - 1, 1,
                                       "\(target) \(kind) \(separator)")
                        XCTAssertFalse(output.content.contains("skip-cert-verify=true"))
                    }
                }
            }
        }
    }

    func testCanonicalTrojanSubscriptionPreservesImportedPin() throws {
        let parser = SubscriptionParser()
        let original = try XCTUnwrap(parser.parseURI("trojan://password@pin.example.com:443?sni=pin.example.com&pinSHA256=\(pin)#Pinned"))
        let link = ProxyNodeShareLinkGenerator().canonicalLink(for: original)
        let restored = try XCTUnwrap(parser.parseURI(link))
        XCTAssertEqual(restored.certificateFingerprint, original.certificateFingerprint)
    }

    func testPlainSurgeNodesDoNotAcquireTLSParameters() {
        for kind: ProxyKind in [.vmess, .http, .socks5] {
            let output = ConfigurationGenerator().generateNodeSubscription(nodes: [node(kind, tls: false)], target: .surge, profileName: "Pins")
            XCTAssertFalse(output.content.contains("server-cert-fingerprint-sha256"))
        }
    }

    func testLoonAndQuantumultPreserveTrojanCertificatePin() {
        for target: ClientTarget in [.loon, .quanx] {
            let output = ConfigurationGenerator().generate(nodes: [node(.trojan)], preset: RulePreset.builtIns[0], target: target)
            XCTAssertTrue(output.content.contains("tls-cert-sha256=\(pin)"), "\(target)")
            XCTAssertFalse(output.content.contains("tls-verification=false"))
            XCTAssertFalse(output.content.contains("skip-cert-verify=true"))
        }
    }

    func testSingBoxTargetsSkipCertificatePinsTheyCannotRepresent() {
        // sing-box's public-key SHA-256 is not a leaf-certificate digest.
        for target: ClientTarget in [.singBox, .hiddify] {
            for kind: ProxyKind in [.trojan, .hysteria2] {
                let output = ConfigurationGenerator().generate(nodes: [node(kind)], preset: RulePreset.builtIns[0], target: target)
                XCTAssertEqual(output.supportedNodeCount, 0)
                XCTAssertEqual(output.skippedNodeCount, 1)
                XCTAssertFalse(output.content.contains("pin.example.com"))
            }
        }
    }

    func testEgernAndClashRetainCertificatePins() {
        for target: ClientTarget in [.egern, .clash, .surge, .surgeMac] {
            let output = ConfigurationGenerator().generate(nodes: [node(.trojan)], preset: RulePreset.builtIns[0], target: target)
            XCTAssertEqual(output.supportedNodeCount, 1)
            XCTAssertTrue(output.content.contains(pin), "\(target)")
        }
    }
}

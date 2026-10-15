import XCTest
@testable import Tower

/// SSH and TrustTunnel arrive as Clash YAML (neither has a share-link
/// scheme) and leave in each client's own spelling. The exported shapes were
/// run against mihomo 1.19.31 and sing-box 1.14.2 before these were written.
final class SSHTrustTunnelTests: XCTestCase {
    private let parser = SubscriptionParser()
    private let key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBfaXh0dXJlLWtleS1ub3QtcmVhbC0tLS0tLS0tLS0tLQAAAJBmaXh0dXJl
    -----END OPENSSH PRIVATE KEY-----
    """
    private let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZpeHR1cmUtaG9zdC1rZXk"

    private func content(_ nodes: [ProxyNode], _ target: ClientTarget) -> String {
        ConfigurationGenerator().generate(nodes: nodes, preset: RulePreset.builtIns[0], target: target).content
    }

    private func sshYAML(extra: String = "") -> String {
        let indentedKey = key.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n")
        return """
        proxies:
          - name: SSH Key
            type: ssh
            server: ssh.example.com
            port: 22
            username: tower
            private-key: |
        \(indentedKey)
        \(extra)
          - name: After
            type: ss
            server: ss.example.com
            port: 443
            cipher: aes-128-gcm
            password: pw
        """
    }

    // MARK: - Parsing

    func testParsesSSHWithABlockScalarKeyAndKeepsTheNextNode() throws {
        let parsed = parser.parse(data: Data(sshYAML(extra: "    host-key:\n      - \"\(hostKey)\"").utf8))
        XCTAssertEqual(parsed.nodes.map(\.name), ["SSH Key", "After"])
        let node = try XCTUnwrap(parsed.nodes.first)
        XCTAssertEqual(node.kind, .ssh)
        XCTAssertEqual(node.username, "tower")
        XCTAssertEqual(node.ssh?.privateKey, key + "\n")
        XCTAssertEqual(node.ssh?.hostKeys, [hostKey])
    }

    func testAcceptsStashUserAndRejectsKeyFilePaths() {
        let stash = "proxies:\n  - {name: S, type: ssh, server: a.example.com, port: 22, user: tower, password: pw}\n"
        XCTAssertEqual(parser.parse(data: Data(stash.utf8)).nodes.first?.username, "tower")
        let path = "proxies:\n  - {name: P, type: ssh, server: a.example.com, port: 22, username: tower, private-key: ~/.ssh/id_ed25519}\n"
        let parsed = parser.parse(data: Data(path.utf8))
        XCTAssertTrue(parsed.nodes.isEmpty)
        XCTAssertEqual(parsed.rejectedLineCount, 1)
    }

    func testParsesTrustTunnel() throws {
        let yaml = "proxies:\n  - {name: T, type: trusttunnel, server: t.example.com, port: 443, username: u, password: p, sni: t.example.com, quic: true, udp: true}\n"
        let node = try XCTUnwrap(parser.parse(data: Data(yaml.utf8)).nodes.first)
        XCTAssertEqual(node.kind, .trustTunnel)
        XCTAssertTrue(node.tls)
        XCTAssertEqual(node.trustTunnel?.quic, true)
        XCTAssertEqual(node.udpRelayEnabled, true)
    }

    // MARK: - Export

    private var passwordSSH: ProxyNode {
        ProxyNode(kind: .ssh, name: "SSH", server: "ssh.example.com", port: 22, password: "pw",
                  username: "tower", rawURI: "", ssh: SSHOptions(hostKeys: [hostKey]))
    }

    private var keySSH: ProxyNode {
        ProxyNode(kind: .ssh, name: "SSH Key", server: "ssh.example.com", port: 22,
                  username: "tower", rawURI: "", ssh: SSHOptions(privateKey: key + "\n"))
    }

    private var trustTunnel: ProxyNode {
        ProxyNode(kind: .trustTunnel, name: "TT", server: "t.example.com", port: 443, password: "p",
                  username: "u", tls: true, sni: "t.example.com", rawURI: "",
                  trustTunnel: TrustTunnelOptions(quic: true))
    }

    func testEachClientGetsItsOwnSSHSpelling() throws {
        let mihomo = content([keySSH], .clashApple)
        XCTAssertTrue(mihomo.contains("    username: \"tower\""), mihomo)
        XCTAssertTrue(mihomo.contains("    private-key: \"-----BEGIN OPENSSH PRIVATE KEY-----\\n"), mihomo)
        XCTAssertTrue(content([keySSH], .clash).contains("    user: \"tower\""))
        XCTAssertTrue(content([passwordSSH], .clashApple).contains("    host-key: [\"\(hostKey)\"]"))

        let surge = content([passwordSSH], .surge)
        XCTAssertTrue(surge.contains("= ssh, ssh.example.com, 22, username=tower, password=pw, server-fingerprint=\"\(hostKey)\""), surge)

        let egern = content([keySSH], .egern)
        XCTAssertTrue(egern.contains("  - ssh:"), egern)
        XCTAssertTrue(egern.contains("      private_key: \"-----BEGIN"), egern)
        XCTAssertFalse(egern.contains("udp_relay"), egern)

        let singBox = content([passwordSSH], .singBox)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(singBox.utf8)) as? [String: Any])
        let outbound = try XCTUnwrap((json["outbounds"] as? [[String: Any]])?.first { $0["type"] as? String == "ssh" })
        XCTAssertEqual(outbound["user"] as? String, "tower")
        XCTAssertEqual(outbound["host_key"] as? [String], [hostKey])
    }

    func testSSHIsSkippedWhereAClientCannotKeepItsAuthentication() {
        // Surge keeps keys in [Keystore]; Stash has no host-key pin.
        XCTAssertFalse(content([keySSH], .surge).contains("ssh.example.com"))
        XCTAssertFalse(content([passwordSSH], .clash).contains("ssh.example.com"))
        var passphrase = keySSH
        passphrase.ssh?.privateKeyPassphrase = "secret"
        XCTAssertFalse(content([passphrase], .egern).contains("ssh.example.com"))
        XCTAssertTrue(content([passphrase], .clashApple).contains("private-key-passphrase"))
        for target in [ClientTarget.loon, .quanx] {
            XCTAssertFalse(target.supports(.ssh), target.name)
        }
        // Shadowrocket dropped key-based sessions on device; passwords worked.
        XCTAssertFalse(content([keySSH], .shadowrocket).contains("ssh.example.com"))
        XCTAssertTrue(content([passwordSSH], .shadowrocket).contains("ssh.example.com"))
    }

    func testEachClientGetsItsOwnTrustTunnelSpelling() {
        let mihomo = content([trustTunnel], .clashApple)
        XCTAssertTrue(mihomo.contains("    type: trusttunnel"), mihomo)
        XCTAssertTrue(mihomo.contains("    quic: true"), mihomo)
        XCTAssertTrue(content([trustTunnel], .clash).contains("    quic: true"))
        // Stash only connected over HTTP/3.
        var http2 = trustTunnel
        http2.trustTunnel = TrustTunnelOptions(quic: false)
        XCTAssertFalse(content([http2], .clash).contains("t.example.com"))
        XCTAssertTrue(content([http2], .clashApple).contains("t.example.com"))
        let surge = content([trustTunnel], .surge)
        XCTAssertTrue(surge.contains("= trust-tunnel, t.example.com, 443, username=u, password=p, h3=true"), surge)
        for target in [ClientTarget.singBox, .hiddify, .egern, .loon, .quanx, .karing] {
            XCTAssertFalse(target.supports(.trustTunnel), target.name)
        }
    }

    // MARK: - Sharing and node lists

    func testSharedSnippetReimportsAsTheSameNode() throws {
        let snippet = ProxyNodeShareLinkGenerator().canonicalLink(for: keySSH)
        XCTAssertTrue(snippet.hasPrefix("proxies:"))
        XCTAssertEqual(SourceInputDetector().detect(snippet), .node(.ssh))
        let node = try XCTUnwrap(parser.parse(data: Data(snippet.utf8)).nodes.first)
        XCTAssertEqual(node.ssh?.privateKey, keySSH.ssh?.privateKey)
        XCTAssertEqual(parser.parse(data: Data(ProxyNodeShareLinkGenerator().canonicalLink(for: trustTunnel).utf8))
            .nodes.first?.trustTunnel?.quic, true)
    }

    func testShadowrocketNodeListUsesYAMLForThem() {
        let list = ConfigurationGenerator().generateNodeSubscription(
            nodes: [passwordSSH, trustTunnel], target: .shadowrocket, profileName: "Audit"
        )
        XCTAssertEqual(list.supportedNodeCount, 2)
        XCTAssertTrue(list.content.hasPrefix("proxies:"), list.content)
    }

    // MARK: - Manual form

    func testManualFormBuildsBothProtocols() throws {
        var draft = ManualNodeDraft()
        draft.applyDefaults(for: .ssh)
        draft.server = "ssh.example.com"
        draft.port = "22"
        XCTAssertThrowsError(try draft.makeNode())
        draft.username = "tower"
        draft.sshPrivateKey = key
        draft.sshHostKey = hostKey
        let ssh = try draft.makeNode()
        XCTAssertEqual(ssh.ssh?.hostKeys, [hostKey])
        XCTAssertNil(ssh.password)
        XCTAssertEqual(ManualNodeDraft(node: ssh).sshPrivateKey, key)

        var tt = ManualNodeDraft()
        tt.applyDefaults(for: .trustTunnel)
        tt.server = "t.example.com"
        tt.port = "443"
        tt.username = "u"
        XCTAssertThrowsError(try tt.makeNode())
        tt.secret = "p"
        tt.trustTunnelQUIC = true
        let node = try tt.makeNode()
        XCTAssertTrue(node.tls)
        XCTAssertEqual(node.trustTunnel?.quic, true)
        XCTAssertEqual(node.password, "p")
    }
}

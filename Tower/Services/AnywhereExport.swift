import Foundation

/// Anywhere's node-URI dialect, verified against upstream 9ae49a73a0cf.
/// This client imports subscriptions, not Tower's policy groups and rules.
enum AnywhereExport {
    /// Clash's `client-fingerprint` names mapped exactly as Anywhere's own
    /// Clash importer maps them (ClashProxyParser.mapFingerprint, upstream
    /// 124ec879a313). `random` becomes Anywhere's default, so the parameter
    /// is left out rather than written.
    private static let fingerprints: [String: String?] = [
        "chrome": "chrome_133", "firefox": "firefox_148", "safari": "safari_26",
        "ios": "chrome_120", "edge": "edge_106", "random": nil, "randomized": nil
    ]
    private static let nativeFingerprints: Set<String> = [
        "chrome_133", "chrome_120", "chrome_106", "firefox_148", "firefox_120",
        "safari_26", "edge_106", "non_browser"
    ]

    static func supports(_ node: ProxyNode) -> Bool {
        unsupportedReason(node) == nil
    }

    /// Why a node cannot be written for Anywhere, or nil when it can.
    static func unsupportedReason(_ node: ProxyNode) -> String? {
        if node.kind == .vless, UUID(uuidString: node.uuid ?? "") == nil {
            return String(localized: "节点认证信息无效或不完整。")
        }
        // Anywhere's parsers have no field for these; never silently weaken
        // a pin or drop a requirement. Dropping skip-cert-verify would make
        // the node fail its handshake: it would look fine and not connect.
        if node.skipCertificateVerification {
            return String(localized: "Anywhere 总是校验服务器证书，无法保留此节点的“跳过证书校验”，导出后会连接失败。")
        }
        if !(node.certificateFingerprint ?? "").isEmpty {
            return String(localized: "Anywhere 不支持证书指纹固定。")
        }
        if node.udpRelayEnabled == false {
            return String(localized: "Anywhere 无法关闭此节点的 UDP 转发。")
        }
        if let fp = node.fingerprint, !fp.isEmpty,
           fingerprints[fp.lowercased()] == nil, !nativeFingerprints.contains(fp) {
            return String(localized: "Anywhere 不支持 TLS 指纹 \(fp)。")
        }
        if !(node.portHopping ?? "").isEmpty || !(node.plugin ?? "").isEmpty {
            return String(localized: "Anywhere 不支持此节点的端口跳跃或插件。")
        }
        let transport = node.transport?.lowercased() ?? "tcp"
        if (node.usesReality && node.kind != .vless) || (node.kind != .vless && !["", "tcp"].contains(transport)) {
            return String(localized: "Anywhere 只有 VLESS 支持 Reality 和 TCP 以外的传输方式。")
        }
        let supported: Bool
        switch node.kind {
        case .shadowsocks:
            supported = !node.tls && (node.obfs ?? "none") == "none"
                && ["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "chacha20-poly1305",
                    "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
                    "2022-blake3-chacha20-poly1305", "none"].contains(node.cipher ?? "")
                && node.password != nil
        case .socks5:
            supported = !node.tls
        case .hysteria2:
            supported = (node.alpn ?? "").isEmpty
                && ["", "none", "salamander", "gecko"].contains(node.obfs?.lowercased() ?? "")
        default:
            supported = true
        }
        return supported ? nil : String(localized: "此节点的协议参数无法在当前客户端完整保留。")
    }

    static func link(for node: ProxyNode) -> String {
        let canonical = ProxyNodeShareLinkGenerator().canonicalLink(for: node)
        guard node.kind != .shadowsocks,
              var url = URLComponents(string: canonical) else { return canonical }
        var items = url.queryItems ?? []
        let aliases = ["idle-session-check-interval": "ici", "idle-session-timeout": "it", "min-idle-session": "mis"]
        items = items.map { item in
            if node.kind == .vless, node.transport == "grpc", item.name == "host" {
                return URLQueryItem(name: "authority", value: item.value)
            }
            if let alias = aliases[item.name] { return URLQueryItem(name: alias, value: item.value) }
            if item.name == "fp", let value = item.value, let mapped = fingerprints[value.lowercased()] {
                return URLQueryItem(name: "fp", value: mapped)
            }
            return item
        }.filter { !($0.name == "fp" && $0.value == nil) }
        // SOCKS5's parser expects host:port with no URI query suffix.
        if node.kind == .socks5 { items = [] }
        if node.kind == .vless, let flow = node.flow, !flow.isEmpty,
           !items.contains(where: { $0.name == "flow" }) {
            items.append(URLQueryItem(name: "flow", value: flow))
        }
        if node.kind == .hysteria2 {
            if let up = node.upMbps { items.append(URLQueryItem(name: "upmbps", value: String(up))) }
            if let down = node.downMbps { items.append(URLQueryItem(name: "downmbps", value: String(down))) }
        }
        url.queryItems = items.isEmpty ? nil : items
        return url.string ?? canonical
    }
}

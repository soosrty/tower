import Foundation

/// Chooses the smallest native representation that is still accepted by the
/// target client. A remote URL is never emitted merely because it ends in
/// `.list`: the cached payload must use that client's rule-set dialect.
struct RuleSetEmissionPlanner {
    enum NativeFormat: Equatable {
        case classicalText
        case clashProviderYAML
        case clashDomainMRS
        case clashIPCIDRMRS
        case quanXFilter
        case singBoxSource
        case singBoxBinarySRS
        case egernYAML
    }

    struct RemoteResource: Equatable {
        let identifier: String
        let url: URL
        let policyName: String
        let format: NativeFormat
        var options: [String] = []
        var provider: RuleProviderMetadata? = nil
    }

    struct InlineRule: Equatable {
        let policyName: String
        let line: String
    }

    enum Entry: Equatable {
        case remote(RemoteResource)
        case inline(InlineRule)
    }

    /// A binary MRS rule set the target cannot read or reference.
    struct UnreadableResource: Equatable {
        let policyName: String
        let url: URL
    }

    struct Plan: Equatable {
        let entries: [Entry]
        let finalGroupName: String?
        var finalOptions: [String] = []
        var unreadableResources: [UnreadableResource] = []

        var remoteResources: [RemoteResource] {
            entries.compactMap {
                guard case .remote(let resource) = $0 else { return nil }
                return resource
            }
        }

        var inlineRules: [InlineRule] {
            entries.compactMap {
                guard case .inline(let rule) = $0 else { return nil }
                return rule
            }
        }
    }

    private let repository: RuleSchemeRepository

    init(repository: RuleSchemeRepository) {
        self.repository = repository
    }

    func plan(
        for scheme: RuleScheme,
        target: ClientTarget,
        preferRuleSets: Bool
    ) -> Plan {
        var entries: [Entry] = []
        var finalGroupName: String?
        var finalOptions: [String] = []
        var remoteIndex = 0
        // What each generic remote entry expands to if it has to be inlined.
        var inlineFallbacks: [Int: [Entry]] = [:]
        var unreadable: [UnreadableResource] = []

        for ruleset in scheme.rulesets {
            // Only mihomo reads MRS, and it can only fetch it: there are no
            // lines to write locally, whatever the rule-set preference.
            if ruleset.isBinaryRuleSet, let url = ruleset.resource.downloadURL {
                let behavior = ruleset.provider?.behavior?.lowercased()
                if Self.mrsTargets.contains(target), behavior == "domain" || behavior == "ipcidr" {
                    remoteIndex += 1
                    entries.append(.remote(RemoteResource(
                        identifier: identifier(for: url, index: remoteIndex, suffix: behavior == "ipcidr" ? "ip" : "domain"),
                        url: url,
                        policyName: ruleset.groupName,
                        format: behavior == "ipcidr" ? .clashIPCIDRMRS : .clashDomainMRS,
                        options: ruleset.options ?? [],
                        provider: ruleset.provider
                    )))
                } else {
                    unreadable.append(UnreadableResource(policyName: ruleset.groupName, url: url))
                }
                continue
            }
            if ruleset.resource.domainSetURL != nil, !([.surge, .surgeMac].contains(target) && preferRuleSets) {
                let options: [String]
                if case .inline(let body) = ruleset.resource {
                    options = RoutingRuleSyntax.condition(body)?.options ?? []
                } else { options = ruleset.options ?? [] }
                entries.append(contentsOf: repository.lines(for: ruleset.resource).map {
                    .inline(InlineRule(policyName: ruleset.groupName, line: RuleResourceContent.applying(options, to: $0)))
                })
                continue
            }
            switch ruleset.resource {
            case .inline(let line):
                if line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "FINAL" {
                    finalGroupName = ruleset.groupName
                    finalOptions = ruleset.options ?? []
                } else {
                    entries.append(.inline(InlineRule(policyName: ruleset.groupName, line: line)))
                }

            case .remote(let url):
                let lines = repository.lines(for: ruleset.resource)
                if preferRuleSets, ruleset.options == nil, ruleset.provider == nil,
                   [.clash, .clashApple, .clashVerge, .clashMac, .flClash, .mihomoParty, .clashMi].contains(target),
                   let optimized = optimizedClashEntries(
                    resource: ruleset.resource,
                    sourceURL: url,
                    lines: lines,
                    policyName: ruleset.groupName,
                    startingRemoteIndex: remoteIndex
                   ) {
                    entries.append(contentsOf: optimized.entries)
                    remoteIndex = optimized.finalRemoteIndex
                } else if preferRuleSets, ruleset.options == nil, ruleset.provider == nil,
                          target == .singBox,
                          let optimized = optimizedSingBoxEntries(
                            resource: ruleset.resource,
                            sourceURL: url,
                            lines: lines,
                            policyName: ruleset.groupName,
                            startingRemoteIndex: remoteIndex
                          ) {
                    entries.append(contentsOf: optimized.entries)
                    remoteIndex = optimized.finalRemoteIndex
                } else if preferRuleSets,
                   RoutingRuleCapabilities.optionsSupported((ruleset.options ?? []).filter { !$0.hasPrefix("update-interval=") }, target: target),
                   let format = providerFormat(ruleset, target: target, lines: lines) ?? nativeFormat(
                    for: target,
                    url: url,
                    lines: lines,
                    isClashProviderYAML: repository.isClashProviderYAML(ruleset.resource)
                   ) {
                    remoteIndex += 1
                    inlineFallbacks[entries.count] = RuleResourceContent.normalized(lines, behavior: ruleset.provider?.behavior).map {
                        .inline(InlineRule(policyName: ruleset.groupName, line: RuleResourceContent.applying(ruleset.options ?? [], to: $0)))
                    }
                    entries.append(.remote(RemoteResource(
                        identifier: identifier(for: url, index: remoteIndex),
                        url: url,
                        policyName: ruleset.groupName,
                        format: format,
                        options: ruleset.options ?? [], provider: ruleset.provider
                    )))
                } else {
                    entries.append(contentsOf: RuleResourceContent.normalized(lines, behavior: ruleset.provider?.behavior).map {
                        .inline(InlineRule(policyName: ruleset.groupName, line: RuleResourceContent.applying(ruleset.options ?? [], to: $0)))
                    })
                }
            }
        }

        // Loon and Quantumult X keep remote rule lists in their own section
        // and match every local rule before any of them (Loon: local > plugin
        // > remote; Quantumult X: filter_local > filter_remote). A list that
        // came before a local rule would lose to it, so it is inlined instead.
        if [.loon, .quanx].contains(target),
           let lastInline = entries.lastIndex(where: { if case .inline = $0 { return true } else { return false } }) {
            entries = entries.indices.flatMap { index -> [Entry] in
                guard index < lastInline, let fallback = inlineFallbacks[index] else { return [entries[index]] }
                return fallback
            }
        }

        return Plan(entries: entries, finalGroupName: finalGroupName, finalOptions: finalOptions, unreadableResources: unreadable)
    }

    /// Karing is left out: its core is sing-box, which has no MRS reader.
    private static let mrsTargets: Set<ClientTarget> = [.clashApple, .clashVerge, .clashMac, .flClash, .mihomoParty, .clashMi]

    /// MRS supports compact domain and CIDR tries, not the mixed `classical`
    /// grammar used by ACL4SSR. Tower therefore emits verified binary slices
    /// and keeps every rule that cannot be represented by that slice inline.
    /// Returning `nil` means no binary alternative exists and preserves the
    /// pre-existing classical provider/inline fallback unchanged.
    private func optimizedClashEntries(
        resource: RuleSchemeRuleset.Resource,
        sourceURL: URL,
        lines: [String],
        policyName: String,
        startingRemoteIndex: Int
    ) -> (entries: [Entry], finalRemoteIndex: Int)? {
        let alternatives = repository.clashMRSResources(
            for: resource,
            matching: lines
        )
        guard !alternatives.isEmpty, !lines.isEmpty else { return nil }

        let domainTypes: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX"]
        let ipTypes: Set<String> = ["IP-CIDR", "IP-CIDR6", "IP6-CIDR"]
        let hasDomainRules = lines.contains { domainTypes.contains(ruleType(in: $0)) }
        let hasIPRules = lines.contains { ipTypes.contains(ruleType(in: $0)) }

        var coveredTypes: Set<String> = []
        var entries: [Entry] = []
        var remoteIndex = startingRemoteIndex

        for alternative in alternatives {
            let shouldEmit: Bool
            let format: NativeFormat
        var options: [String] = []
            let suffix: String
            switch alternative.behavior {
            case .domain:
                shouldEmit = hasDomainRules
                format = .clashDomainMRS
                suffix = "domain"
                if shouldEmit { coveredTypes.formUnion(domainTypes) }
            case .ipcidr:
                shouldEmit = hasIPRules
                format = .clashIPCIDRMRS
                suffix = "ip"
                if shouldEmit { coveredTypes.formUnion(ipTypes) }
            }
            guard shouldEmit else { continue }

            remoteIndex += 1
            entries.append(.remote(RemoteResource(
                identifier: identifier(for: sourceURL, index: remoteIndex, suffix: suffix),
                url: alternative.url,
                policyName: policyName,
                format: format
            )))
        }

        guard !entries.isEmpty else { return nil }
        entries.append(contentsOf: lines.compactMap { line in
            guard !coveredTypes.contains(ruleType(in: line)) else { return nil }
            return .inline(InlineRule(policyName: policyName, line: line))
        })
        return (entries, remoteIndex)
    }

    /// sing-box source-format v2 can compile the destination matchers used by
    /// ACL4SSR into one binary SRS. The manifest records exactly which source
    /// types were converted; all other lines remain in their original place.
    private func optimizedSingBoxEntries(
        resource: RuleSchemeRuleset.Resource,
        sourceURL: URL,
        lines: [String],
        policyName: String,
        startingRemoteIndex: Int
    ) -> (entries: [Entry], finalRemoteIndex: Int)? {
        guard let alternative = repository.singBoxSRSResource(
            for: resource,
            matching: lines
        ),
              !lines.isEmpty else { return nil }

        let sourceTypes = Set(lines.map(ruleType(in:)))
        let coveredTypes = alternative.coveredRuleTypes.intersection(sourceTypes)
        guard !coveredTypes.isEmpty else { return nil }

        let remoteIndex = startingRemoteIndex + 1
        var entries: [Entry] = [
            .remote(RemoteResource(
                identifier: identifier(for: sourceURL, index: remoteIndex, suffix: "srs"),
                url: alternative.url,
                policyName: policyName,
                format: .singBoxBinarySRS
            ))
        ]
        entries.append(contentsOf: lines.compactMap { line in
            guard !coveredTypes.contains(ruleType(in: line)) else { return nil }
            return .inline(InlineRule(policyName: policyName, line: line))
        })
        return (entries, remoteIndex)
    }

    private func providerFormat(_ ruleset: RuleSchemeRuleset, target: ClientTarget, lines: [String]) -> NativeFormat? {
        guard target.usesClashFormat, let metadata = ruleset.provider,
              ["domain", "ipcidr", "domain-text", "ipcidr-text"].contains(metadata.behavior ?? ""),
              !lines.isEmpty else { return nil }
        return repository.isClashProviderYAML(ruleset.resource) ? .clashProviderYAML : .classicalText
    }

    private func nativeFormat(
        for target: ClientTarget,
        url: URL,
        lines: [String],
        isClashProviderYAML: Bool
    ) -> NativeFormat? {
        switch target {
        case .clashApple, .clashVerge, .clashMac, .flClash, .mihomoParty, .clashMi:
            // Mihomo accepts this Surge domain flag in classical HTTP providers
            // and ignores it, just as for inline domain rules. This preserves
            // ordinary domain matching; it does not enable Surge-style sniffing.
            guard linesAreClassical(lines, allowedTypes: Self.clashRuleTypes, allowExtendedMatching: true) else { return nil }
            return isClashProviderYAML ? .clashProviderYAML : .classicalText
        case .clash:
            // Stash supports classical text providers. Preserve this resource
            // for client validation; do not claim Surge sniffing semantics.
            guard linesAreClassical(lines, allowedTypes: Self.clashRuleTypes, allowExtendedMatching: true) else { return nil }
            return isClashProviderYAML ? .clashProviderYAML : .classicalText
        case .karing:
            guard linesAreClassical(lines, allowedTypes: Self.clashRuleTypes) else { return nil }
            return isClashProviderYAML ? .clashProviderYAML : .classicalText
        case .surge, .surgeMac:
            return !isClashProviderYAML && linesAreClassical(lines, allowedTypes: Self.surgeRuleTypes, allowExtendedMatching: true)
                ? .classicalText
                : nil
        case .shadowrocket:
            // Shadowrocket receives a Clash-compatible YAML profile, so its
            // remote resources use Clash provider syntax. The lines inside
            // still have to stay within Shadowrocket's own rule vocabulary.
            guard linesAreClassical(lines, allowedTypes: Self.shadowrocketRuleTypes) else { return nil }
            return isClashProviderYAML ? .clashProviderYAML : .classicalText
        case .loon:
            return !isClashProviderYAML && linesAreClassical(lines, allowedTypes: Self.loonRuleTypes)
                ? .classicalText
                : nil
        case .quanx:
            return !isClashProviderYAML && linesAreQuanXFilters(lines) ? .quanXFilter : nil
        case .hiddify, .singBox:
            return isSingBoxSource(url: url, lines: lines) ? .singBoxSource : nil
        case .egern:
            return isEgernRuleSet(lines) ? .egernYAML : nil
        case .v2box, .anywhere:
            return nil
        }
    }

    /// Classical remote lists contain only the matcher and its value. A list
    /// that already embeds policies is a complete rule file, not a reusable
    /// rule set, so Tower keeps mapping it locally.
    private func linesAreClassical(
        _ lines: [String],
        allowedTypes: Set<String>,
        allowExtendedMatching: Bool = false
    ) -> Bool {
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            let parts = fields(in: line)
            guard parts.count >= 2,
                  parts.count <= 3,
                  allowedTypes.contains(parts[0].uppercased()) else { return false }
            guard parts.count == 3 else { return true }
            if parts[2].lowercased() == "no-resolve" { return true }
            // Surge permits this flag inside external rule sets. Do not apply
            // it to the RULE-SET reference or assume other dialects support it.
            return allowExtendedMatching
                && parts[2].lowercased() == "extended-matching"
                && ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD", "URL-REGEX"]
                    .contains(parts[0].uppercased())
        }
    }

    private func linesAreQuanXFilters(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            let parts = fields(in: line)
            guard parts.count >= 2,
                  parts.count <= 3,
                  Self.quanXRuleTypes.contains(parts[0].lowercased()) else { return false }
            // Native QuanX filter resources commonly carry their own policy
            // as field three. Tower's `force-policy` overrides it. In contrast,
            // `no-resolve` is a Surge/Clash option that QuanX does not accept;
            // reject that resource so it is normalized through the local path.
            return parts.count == 2
                || (!parts[2].isEmpty && parts[2].lowercased() != "no-resolve")
        }
    }

    private func isSingBoxSource(url: URL, lines: [String]) -> Bool {
        guard url.pathExtension.lowercased() == "json",
              let data = lines.joined(separator: "\n").data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["rules"] is [[String: Any]] else { return false }
        return true
    }

    private func isEgernRuleSet(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        let keys = Set(lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("-"), trimmed.hasSuffix(":") else { return nil }
            return String(trimmed.dropLast())
        })
        return !keys.isDisjoint(with: Self.egernRuleSetKeys)
            && keys.subtracting(Self.egernRuleSetKeys.union(["no_resolve"])).isEmpty
    }

    private func fields(in line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func ruleType(in line: String) -> String {
        fields(in: line).first?.uppercased() ?? ""
    }

    private func identifier(for url: URL, index: Int, suffix: String? = nil) -> String {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in base.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "ruleset" }
        if let suffix { slug += "-\(suffix)" }
        return "tower-\(slug)-\(index)"
    }

    private static let clashRuleTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6",
        "IP6-CIDR", "GEOIP", "GEOSITE", "SRC-IP-CIDR", "SRC-PORT", "DST-PORT",
        "PROCESS-NAME", "PROCESS-PATH", "PROCESS-PATH-REGEX", "NETWORK"
    ]

    private static let surgeRuleTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-SET", "DOMAIN-WILDCARD",
        "IP-CIDR", "IP-CIDR6", "IP6-CIDR", "IP-ASN", "GEOIP", "PROCESS-NAME",
        "USER-AGENT", "URL-REGEX", "DEST-PORT", "SRC-IP", "SRC-PORT", "IN-PORT",
        "PROTOCOL", "SUBNET"
    ]

    /// Loon's remote rule lists (nsloon.app/docs/Rule/sub_rule).
    private static let loonRuleTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6",
        "GEOIP", "IP-ASN", "USER-AGENT", "URL-REGEX"
    ]

    /// Shadowrocket's documented rule types, without its logical rules.
    private static let shadowrocketRuleTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD", "USER-AGENT",
        "URL-REGEX", "IP-CIDR", "IP-CIDR6", "IP-ASN", "GEOIP", "DST-PORT"
    ]

    private static let quanXRuleTypes: Set<String> = [
        "host", "host-suffix", "host-keyword", "host-wildcard",
        "ip-cidr", "ip6-cidr", "geoip", "ip-asn", "user-agent"
    ]

    private static let egernRuleSetKeys: Set<String> = [
        "domain_set", "domain_keyword_set", "domain_suffix_set", "domain_regex_set",
        "domain_wildcard_set", "geoip_set", "ip_cidr_set", "ip_cidr6_set",
        "url_regex_set", "asn_set", "user_agent_set", "ssid_set", "bssid_set",
        "cellular_set", "protocol_set", "dest_port_set", "and_set", "or_set", "not_set"
    ]
}

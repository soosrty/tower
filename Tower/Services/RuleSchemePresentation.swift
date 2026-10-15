import Foundation

/// Display-only values survive invalidation while a new snapshot is prepared.
/// They are never used to export or mutate rules.
struct RuleSchemePageSummary {
    let preview: RuleScheme
    let count: Int
    let isReady: Bool
}

/// A value snapshot, shared by synchronous export and background page preparation.
struct RuleSchemePresentation {
    let scheme: RuleScheme
    let customization: RuleSchemeCustomization?
    let flows: [CustomRuleFlow]
    let selectedGroups: Set<String>?

    func resolveLines(using repository: RuleSchemeRepository) -> [URL: [String]] {
        let enabledFlows = flows.filter { $0.schemeID == scheme.id && $0.isEnabled }
        // Only conflict placement of added rules needs the upstream contents.
        guard !enabledFlows.isEmpty else { return [:] }
        let urls = scheme.remoteRulesetURLs + enabledFlows.compactMap(\.remoteRuleURL)
        return Dictionary(uniqueKeysWithValues: Set(urls).map {
            ($0, repository.lines(for: .remote($0)))
        })
    }

    func materialize(preview: Bool, resolvedLines: [URL: [String]]) -> RuleScheme {
        let fixed = Set(scheme.protectedRuleGroupNames)
            .intersection(scheme.selectableRuleGroupNames)
            .map { customization?.renamedGroupName($0) ?? $0 }
        return scheme.customized(
            enabledRuleGroupNames: preview ? nil : selectedGroups.map { $0.union(fixed) },
            customRuleFlows: flows,
            groupCustomization: customization,
            resolvedRuleLines: resolvedLines
        )
    }
}

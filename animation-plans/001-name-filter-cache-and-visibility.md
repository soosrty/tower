# 001 — 节点名称导出筛选：勾选时不再重跑正则，失败原因在导出页可见

- **Status**: DONE（2026-09-27）
- **Commit**: `5672973`，**加工作区未提交改动**（`nodeExportNameFilter` 整套功能尚未提交，本计划基于工作区版本）
- **Severity**: HIGH（逻辑 / 算法，非动画）
- **Category**: 算法与流程（导出正确性、主线程耗时）
- **Estimated scope**: 3 个文件（`Tower/AppModel.swift`、`Tower/Features/Export/ExportView.swift`、`TowerTests/NodeSelectionTests.swift`），约 60 行

## Problem

`Tower/AppModel.swift:258-296`（工作区版本）的 `nodeSelection` 在**主线程**同步执行名称正则，用的是 1 秒墙钟预算：

```swift
// Tower/AppModel.swift:276-289 — current
var nameMatchedIDs = Set(available.map(\.id))
var nameFilterError: String?
if let filter = inputs.nameFilter {
    do {
        let indices = try NodeNameFilterMatcher.preview(
            filter.pattern, candidates: available.map { [$0.name] },
            caseInsensitive: filter.ignoresCase
        )
        nameMatchedIDs = Set(indices.map { available[$0].id })
    } catch {
        // A malformed or expensive expression must never silently
        // broaden an export to every node.
        nameMatchedIDs = []
        nameFilterError = error.localizedDescription
    }
}
```

这个缓存会被以下属性的 `didSet` 整个作废（`AppModel.swift:45-53, 125, 154, 157`）：`subscriptions`、`nodes`、`filterSubscriptionInfoNodes`、`excludedNodeIDs`、`nodeExportNameFilter`。

后果：

1. **每点一次节点勾选框**（`setNode` 改 `excludedNodeIDs`）都会对全部可用节点重跑一遍正则。可是名称匹配结果和勾选状态完全无关。节点多、正则复杂时，这相当于在高频点击路径上最多卡住主线程 1 秒。
2. 预算按墙钟计时，并且覆盖整批候选。筛选弹窗（`NodeFilterView.swift` 的 `NodeExportNameFilterSheet`）通过 `NodeNameFilterPreviewInput.evaluate()` 在后台线程预览（`NodeNameFilterEditor.swift:302`）。于是同一个正则可能在弹窗里通过，到了繁忙的主线程却超时。一旦超时，`nameMatchedIDs = []`，**所有客户端导出都变成 0 个节点**。
3. 发生第 2 点时，导出页只显示“暂时无法导出”（`ExportView.swift:55`），不说原因。原因只出现在批量管理 → 节点筛选页的 footer 里，用户很难找到。

“宁可导出为空也不要静默放宽”是正确的既有设计，不要改。本计划只做两件事：让高频路径不再重复计算；让失败原因出现在用户实际停留的页面。

## Target

- 名称匹配单独缓存，键为 `(filter, 可用节点 id 序列, 名称序列)`。只改勾选状态时命中缓存，不调用 `NodeNameFilterMatcher.preview`。
- 新增 `@ObservationIgnored private(set) var nodeNameFilterEvaluationCount = 0`，与现有 `configurationGenerationCount`（`AppModel.swift:209`）同一模式，供测试断言。
- 导出页：`model.nodeExportNameFilterError != nil` 时，在状态头下方显示一行橙色说明，文案为“节点名称筛选无法完成，当前不会导出节点：\(error)”，并附带一个跳到批量管理筛选页的入口。如果入口实现复杂，至少显示说明文字。

## Repo conventions to follow

- 缓存写法照抄 `nodeSelectionCache`：`@ObservationIgnored` 元组缓存，由输入相等性决定是否命中（参考 `countryCountCache`，`AppModel.swift:298, 1401-1407`）。
- 计数器写法照抄 `configurationGenerationCount`（`AppModel.swift:209`），测试写法照抄 `TowerTests/AuditConsistencyTests.swift:192-194`。
- 新文案必须补齐 15 种语言：先运行 `bash Scripts/check_localization.sh` 找出缺口，再用 `Scripts/generate_localizations.py --source-catalog <Xcode 导出的 Localizable.xcstrings>` 填补（见 `CLAUDE.md`「改动验收」）。

## Steps

1. 在 `AppModel.swift` 的 `nodeSelectionCache` 声明附近新增：
   ```swift
   private struct NodeNameMatchInputs: Equatable {
       let filter: NodeExportNameFilter
       let ids: [UUID]
       let names: [String]
   }
   @ObservationIgnored private var nodeNameMatchCache: (NodeNameMatchInputs, Set<UUID>, String?)?
   @ObservationIgnored private(set) var nodeNameFilterEvaluationCount = 0

   private func nodeNameMatches(for filter: NodeExportNameFilter, in available: [ProxyNode]) -> (Set<UUID>, String?) {
       let inputs = NodeNameMatchInputs(filter: filter, ids: available.map(\.id), names: available.map(\.name))
       if let cached = nodeNameMatchCache, cached.0 == inputs { return (cached.1, cached.2) }
       nodeNameFilterEvaluationCount += 1
       let result: (Set<UUID>, String?)
       do {
           let indices = try NodeNameFilterMatcher.preview(
               filter.pattern, candidates: inputs.names.map { [$0] },
               caseInsensitive: filter.ignoresCase
           )
           result = (Set(indices.map { inputs.ids[$0] }), nil)
       } catch {
           // A malformed or expensive expression must never silently
           // broaden an export to every node.
           result = ([], error.localizedDescription)
       }
       nodeNameMatchCache = (inputs, result.0, result.1)
       return result
   }
   ```
2. 把 `nodeSelection` 里的 `do { … } catch { … }` 块（上面 Problem 引用的第 276-289 行）替换为：
   ```swift
   if let filter = inputs.nameFilter {
       (nameMatchedIDs, nameFilterError) = nodeNameMatches(for: filter, in: available)
   }
   ```
   其余逻辑不变（`enabled` 仍然同时要求名称匹配且未被排除）。**不要**给 `excludedNodeIDs` 等属性的 `didSet` 加清空 `nodeNameMatchCache` 的代码：缓存靠输入相等性自行失效。
3. `ExportView.swift`：在状态头 `HStack`（`accessibilityIdentifier("conversion-status-header")`，约第 52-73 行）之后、`ExportContentModePicker()` 之前，插入：
   ```swift
   if let error = model.nodeExportNameFilterError {
       Label {
           Text("节点名称筛选无法完成，当前不会导出节点：\(error)")
       } icon: {
           Image(systemName: "exclamationmark.triangle.fill")
       }
       .font(.footnote)
       .foregroundStyle(.orange)
       .fixedSize(horizontal: false, vertical: true)
       .padding(.bottom, 12)
       .accessibilityIdentifier("export-name-filter-error")
   }
   ```
   不要给它加动画：这一段外层已经用 `.animation(nil, value: request)` 抑制了生成相关的变化。
4. 在 `TowerTests/NodeSelectionTests.swift` 里仿照 `testSavedNameConditionFiltersNewNodesAndBothExportModes` 新增测试：设置 `(?i)IEPL` 筛选 → 读一次 `enabledNodes` → 记下 `nodeNameFilterEvaluationCount` → 对同一节点连续 `setNode(_, included:)` 切换 3 次、每次都读 `enabledNodes` → 断言计数没有增加，并且 `enabledNodes` 的结果正确。再 `nodes.append(...)` 一个新节点 → 断言计数恰好加 1。
5. 按上面的约定补齐新文案的本地化。

## Boundaries

- 不要改 `NodeNameFilterMatcher.preview` 的超时语义或默认 1 秒预算，也不要把失败改成“放行全部”。
- 不要改筛选弹窗、策略组名称规则（`RuleSchemeGroup` 的名称匹配）或 `ConfigurationGenerator`。
- 不要把匹配挪到后台线程：`enabledNodes` 是所有生成器的同步入口，异步化不在本计划范围内。
- 如果工作区的 `nodeSelection` 与上面的引用不一致（例如功能已经提交或重写），**停下来报告**，不要自行改写。

## Verification

- **Mechanical**：按 `docs/DEVELOPMENT.md` 设置 `DEVELOPER_DIR` 后运行
  `xcodebuild -project Tower.xcodeproj -scheme Tower -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .derived-data-sim test`，
  TowerTests 全部通过，新测试通过；`bash Scripts/check_localization.sh` 无缺口。
- **Feel check**：模拟器导入含数百节点的订阅，设置一个关键词名称筛选。进入批量管理 → 节点筛选，快速连续点 10 个勾选框：每次点击都应立即反馈，没有迟滞。再把筛选改成一个会超时的正则，确认导出页显示橙色说明，且“一键导入”保持禁用。
- **Done when**：只切换勾选时 `nodeNameFilterEvaluationCount` 不增加；超时或非法筛选时，导出页出现 `export-name-filter-error`。

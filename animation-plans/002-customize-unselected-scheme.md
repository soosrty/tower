# 002 — 定制未选中的规则方案时，明确提示并提供“改用此方案”

- **Status**: DONE（2026-09-27）
- **Commit**: `5672973`（加工作区未提交改动；本计划涉及的 `RulesView.swift` 在工作区未改动）
- **Severity**: MEDIUM（流程）
- **Category**: 流程设计
- **Estimated scope**: 1 个源文件（`Tower/Features/Rules/RulesView.swift`），加本地化，约 30 行

## Problem

规则页卡片（`Tower/Features/Rules/RulesView.swift:373-431`）点击面积最大的整块区域执行 `onCustomize`，打开“规则定制”弹窗；真正决定导出用哪套方案的“选中”，只在右上角 44pt 的 `SelectionIndicator`：

```swift
// RulesView.swift:392 — current
Button(action: onCustomize) { … 方案名称、简介、条数 … }
// RulesView.swift:422 — current
Button(action: onSelect) { SelectionIndicator(isSelected: isSelected) … }
```

页面顶部的提示是“点击规则方案即可修改规则”（`RulesView.swift:18`）。定制弹窗 `RuleCustomizationSheet`（`RulesView.swift:664` 起）从头到尾不显示“这套方案是否正在使用”，也不提供切换入口；`model.selectScheme` 只由卡片右上角调用（`RulesView.swift:98, 113, 152`）。

因此有一条很自然的路径会出错：用户点开未选中的方案 B，加规则、改名、排序，点“完成”，再去导出——实际导出的仍是方案 A。整个过程没有任何提示，改动看起来像“没生效”。

## Target

在 `RuleCustomizationSheet` 的 `List` 顶部，当 `model.selectedPresetID != scheme.id` 时插入一个 Section：

- 文字：“导出当前使用「\(model.activeRuleName)」，这里的修改不会影响导出。”
- 按钮：“改用此方案”，执行 `model.selectScheme(scheme)`。点击后这个 Section 消失。
- 不要自动切换方案：切换会改变导出结果，必须由用户明确操作。
- Section 的出现和消失沿用该文件已有的展开节奏：`withAnimation(TowerMotion.disclosure(reduceMotion: reduceMotion))`，内容 `.transition(.opacity)`。它是列表里的一行，由 `List` 的原生行增删动画处理；不要额外加滑入。

## Repo conventions to follow

- 动画 token：`TowerMotion.disclosure(reduceMotion:)`（`Tower/Design/TowerTheme.swift:62-66`），用法参考 `RulesView.swift:74`：
  ```swift
  withAnimation(TowerMotion.disclosure(reduceMotion: reduceMotion)) { model.deleteScheme(deletion) }
  ```
- `RuleCustomizationSheet` 目前没有 `reduceMotion` 环境值，需要新增 `@Environment(\.accessibilityReduceMotion) private var reduceMotion`，写法与 `RulesView` 第 6 行相同。
- 选中触感已经由 `RulesView` 上的 `.sensoryFeedback(.selection, trigger: model.selectedPresetID)` 提供（第 55 行）。弹窗盖在上面时它依然在层级里；不要在弹窗里再加一个触感，以免重复。
- 新文案按 `CLAUDE.md`「改动验收」补齐 15 种语言。

## Steps

1. 在 `RuleCustomizationSheet` 的属性区新增 `@Environment(\.accessibilityReduceMotion) private var reduceMotion`。
2. 新增计算属性：
   ```swift
   @ViewBuilder
   private var schemeUsageSection: some View {
       if model.selectedPresetID != scheme.id {
           Section {
               VStack(alignment: .leading, spacing: 10) {
                   Label {
                       Text("导出当前使用「\(model.activeRuleName)」，这里的修改不会影响导出。")
                           .fixedSize(horizontal: false, vertical: true)
                   } icon: {
                       Image(systemName: "info.circle.fill")
                   }
                   .font(.subheadline)
                   .foregroundStyle(.secondary)
                   Button("改用此方案") {
                       withAnimation(TowerMotion.disclosure(reduceMotion: reduceMotion)) {
                           model.selectScheme(scheme)
                       }
                   }
                   .font(.subheadline.weight(.semibold))
                   .accessibilityIdentifier("customization-use-scheme")
               }
               .padding(.vertical, 4)
           }
           .transition(.opacity)
       }
   }
   ```
3. 把 `List { customRuleGroupsSection … }`（约第 716 行）改为 `List { schemeUsageSection; customRuleGroupsSection; localRuleSetsSection; catalogSections }`。
4. 列表处于 `.environment(\.editMode, .constant(.active))`，要确认这个 Section 不会显示删除 / 拖动控件：它没有 `onDelete` / `onMove`，理论上不会。在模拟器上核对一次。
5. 补齐本地化。

## Boundaries

- 不要改规则卡片的点击分区或顶部提示文案，那是另一个设计决定。
- 不要在“完成”或弹窗关闭时自动选中方案。
- 不要改 `AppModel.selectScheme`。
- 如果 `RuleCustomizationSheet` 的 `List` 结构和上面描述的不同，停下来报告。

## Verification

- **Mechanical**：TowerTests 全部通过（命令见 `docs/DEVELOPMENT.md`）；`bash Scripts/check_localization.sh` 无缺口。可以在 `TowerUITests` 里仿照现有规则流程加一条：打开非选中方案的定制 → 出现 `customization-use-scheme` → 点击 → 按钮消失 → 关闭后该卡片显示为选中。
- **Feel check**：
  - 打开**已选中**方案的定制：顶部没有这个 Section。
  - 打开未选中方案的定制，点“改用此方案”：Section 原地淡出，下面的行平滑上移，没有从顶部滑入的效果（`CLAUDE.md` 约束 7 的精神）。
  - 开启“减弱动态效果”：变化仍然很短，只有透明度过渡。
- **Done when**：在未选中方案的定制页一定能看到当前导出方案的名称和切换按钮；切换后回到规则页，选中框落在该方案上。

# 004 — 添加面板：等剪贴板结果出来再决定是否弹出键盘

- **Status**: DONE（2026-09-27）
- **Commit**: `5672973`（加工作区未提交改动；`AddSourceSheet.swift` 在工作区只改了手动表单的字段，与本计划无关）
- **Severity**: MEDIUM
- **Category**: Purpose & frequency / 流程（避免无意义的键盘升降）
- **Estimated scope**: 1 个文件（`Tower/Features/Subscriptions/AddSourceSheet.swift`），约 15 行

## Problem

每次打开添加面板，都会立即把焦点放进输入框，同时异步读取剪贴板；读到受支持的内容后，又把焦点移走：

```swift
// AddSourceSheet.swift:725-730 — current
private func requestClipboardContent() {
    guard !didReadPasteboard else { return }
    didReadPasteboard = true
    focusedField = .source          // 键盘立刻升起
    readClipboard(automatically: true)
}

// AddSourceSheet.swift:757-771 — current（readClipboard 的完成回调）
Task { @MainActor in
    guard generation == clipboardGeneration, entryMode == .paste,
          sourceValue == originalValue else { return }
    clipboardProgress = nil
    guard !value.isEmpty else { … return }
    guard !automatically || detector.detect(value).isSupported else { return }
    sourceValue = value
    if automatically { initialSourceValue = value }
    focusedField = nil               // 键盘又降下
}
```

“剪贴板里正好有订阅链接”是这个面板最常见的使用方式。偏偏在这种情况下，用户会看到面板升起、键盘升起、系统“允许粘贴”提示出现，然后键盘又降下。键盘的升降占了大半屏，却没有任何用途，还会把检测结果和“添加”按钮来回推动。

`CLAUDE.md` 约束 11 规定：打开面板时自动读取一次剪贴板，只在受支持时自动填充，同一次展示不重复读取，保留手动粘贴按钮。本计划不改变这些行为，只调整焦点时机。

## Target

- 打开面板时**不**主动聚焦。
- 自动读取结束后：
  - 已填充（内容受支持）→ 保持不聚焦，这和现在的最终状态一致。
  - 剪贴板为空、不受支持、读取失败，或者根本没有可读的 provider → 这时再 `focusedField = .source`，让用户可以直接输入。
- 如果用户在结果回来之前已经自己点了输入框、切换了模式或开始输入，现有的 `generation` / `entryMode` / `sourceValue` 守卫会让回调提前返回。这时不要再改焦点，焦点归用户。
- 编辑已有节点（`editingNode != nil`）不读剪贴板，也不自动聚焦，保持现状。

## Repo conventions to follow

- 焦点统一通过 `@FocusState private var focusedField: Field?` 管理（第 30 行）。
- `TowerTests/SubscriptionInteractionTests.swift:277` 断言源码包含 `focusedField = nil`。回调里保留这一行，断言就继续成立。

## Steps

1. `requestClipboardContent()` 删掉 `focusedField = .source` 这一行，其余不动。
2. 在 `readClipboard(automatically:)` 里：
   - “没有可读 provider”的 `guard … else { … return }` 分支中，在 `return` 之前加 `if automatically { focusedField = .source }`。
   - 完成回调中，把
     ```swift
     guard !value.isEmpty else {
         if !automatically { errorMessage = … }
         return
     }
     guard !automatically || detector.detect(value).isSupported else { return }
     ```
     改为
     ```swift
     guard !value.isEmpty else {
         if automatically { focusedField = .source }
         else { errorMessage = String(localized: "等待有效的订阅链接或节点协议") }
         return
     }
     guard !automatically || detector.detect(value).isSupported else {
         focusedField = .source
         return
     }
     ```
   - 最前面的 `guard generation == clipboardGeneration, entryMode == .paste, sourceValue == originalValue else { return }` 保持原样。被守卫拦下时，不改变焦点。
3. 其他地方（模式切换、扫码回调、保存）的焦点逻辑都不动。

## Boundaries

- 不要改剪贴板的读取方式（`itemProviders` + `loadObject`）、自动填充判定，也不要改“从剪贴板重新粘贴”按钮。
- 不要加延时聚焦（例如 `asyncAfter`）。
- 不要改 `ImportRuleSchemeSheet` 的 `.onAppear { focusedField = .url }`：那里不读剪贴板，没有这个问题。
- 如果回调结构和上面的引用不同，停下来报告。

## Verification

- **Mechanical**：TowerTests 全部通过（命令见 `docs/DEVELOPMENT.md`），包括 `SubscriptionInteractionTests.swift:277` 的源码断言。
- **Feel check**（涉及剪贴板和键盘，必须真机验收，见 `CLAUDE.md`「改动验收」）：
  - 复制一个订阅链接，打开添加面板，允许粘贴：**键盘全程不出现**，输入框已填好，检测标签显示“已识别为订阅链接”，“添加”可点。
  - 复制一段普通文字，打开面板，允许粘贴：不自动填充，键盘在读取结束后升起。
  - 清空剪贴板再打开：键盘立即升起。
  - 系统提示出现时点“不允许粘贴”：键盘随后升起，可以直接输入。
  - 系统提示还没关时，先点输入框开始输入：之后不会被填充，焦点也不会跳走。
- **Done when**：剪贴板里有有效链接时，打开面板的全过程中键盘一次都不出现。

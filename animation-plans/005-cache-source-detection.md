# 005 — 添加面板：输入识别结果只算一次，不在每次渲染里重新解析

- **Status**: DONE（2026-09-27）
- **Commit**: `5672973`（加工作区未提交改动；工作区的 `SourceInputDetector.swift` 新增了 JSON 分支，使单次识别更贵）
- **Severity**: MEDIUM（算法 / 主线程耗时）
- **Category**: Performance
- **Estimated scope**: 1 个文件（`Tower/Features/Subscriptions/AddSourceSheet.swift`），约 20 行

## Problem

`detectedKind` 是计算属性，每读一次就完整跑一遍 `SourceInputDetector.detect`：

```swift
// AddSourceSheet.swift:70-72 — current
private var detectedKind: SourceInputKind {
    detector.detect(sourceValue)
}
```

读它的地方有：`detectionLabel`（第 630 行，粘贴区和扫码区都用）、`isSaveDisabled`（第 669-670 行，工具栏按钮）、`saveButtonTitle`（第 661 行），以及 `save()`（第 793 行）。所以面板每渲染一次，至少调用 2 次。

`detect` 对多行文本以及 `{` / `[` 开头的文本，会调用 `SubscriptionParser.parse(data:)`，把**所有节点**完整解析一遍（`SourceInputDetector.swift:22-41`）。`docs/TODO.md` 记录的真实用法是：从 Shadowrocket 批量复制大量节点，粘贴进来。之后每敲一个字、每次焦点变化、每次错误状态变化，都会在主线程上多次全量解析。

## Target

- 在 `@State private var detectedKind: SourceInputKind = .unknown` 里保存识别结果，只在 `sourceValue` 变化时重新计算。
- 对于大文本（`sourceValue.utf8.count > 4_096`），在后台 detached 任务中计算，并用 `.task(id: sourceValue)` 取消过期结果。计算期间 `detectedKind` 保持上一个值，同时“添加”按钮禁用，避免用旧的识别结果保存。
- `save()` 使用已缓存的 `detectedKind`，不再重新识别。

## Repo conventions to follow

- 把纯计算放到后台、结果回到视图任务里发布的写法，照抄 `NodeMapOverview.swift:78-96`：
  ```swift
  let worker = Task.detached(priority: .userInitiated) { … }
  let prepared = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
  guard !Task.isCancelled else { return }
  ```
- `SourceInputDetector` 是值类型，内部持有 `SubscriptionParser`。执行者需要确认它是 `Sendable`，或者可以在 detached 闭包里新建一个；不能跨 actor 共享可变状态。

## Steps

1. 删掉计算属性 `detectedKind`，新增：
   ```swift
   @State private var detectedKind: SourceInputKind = .unknown
   @State private var detectedValue: String = ""
   ```
2. 在 `NavigationStack { Form { … } }` 的修饰符链上（和现有 `.onChange(of: sourceValue)` 放在一起）加：
   ```swift
   .task(id: sourceValue) {
       let value = sourceValue
       let kind: SourceInputKind
       if value.utf8.count > 4_096 {
           let worker = Task.detached(priority: .userInitiated) { SourceInputDetector().detect(value) }
           kind = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
       } else {
           kind = detector.detect(value)
       }
       guard !Task.isCancelled else { return }
       detectedKind = kind
       detectedValue = value
   }
   ```
3. `isSaveDisabled` 的粘贴 / 扫码分支改为：
   ```swift
   if entryMode == .paste || entryMode == .scan {
       return detectedValue != sourceValue || !detectedKind.isSupported
   }
   ```
4. `save()` 里的 `switch detectedKind` 保持不动；它现在读取的是 `@State`。由于第 3 步的守卫，保存时 `detectedValue == sourceValue` 一定成立。
5. 自动剪贴板路径里的 `detector.detect(value).isSupported`（第 767 行）是一次性调用，保持不动。

## Boundaries

- 不要改 `SourceInputDetector` / `SubscriptionParser` 的识别规则。
- 不要改文案或检测标签的外观。
- 不要给检测标签加动画（本计划只处理算法）。
- 如果 `SourceInputDetector` 不能在 detached 闭包里使用（有编译期 Sendable 报错），就把大文本也改成同步计算，只保留第 1-4 步的缓存。这样已经把每次渲染 2 次以上的解析降到了每次输入 1 次。在计划状态里注明这一点即可，不要为此改造解析器。

## Verification

- **Mechanical**：TowerTests 全部通过，尤其是 `LocalNodeImportTests`、`SubscriptionInteractionTests`（命令见 `docs/DEVELOPMENT.md`）。
- **Feel check**：在模拟器里粘贴约 500 行节点 URI，然后在名称框里连续输入：输入没有卡顿；检测标签显示“已识别 N 个节点”；“添加”可点，添加后节点数正确。粘贴后立刻点“添加”：按钮会短暂禁用，直到识别完成，不会用空结果保存。
- **Done when**：面板渲染时不再调用 `detector.detect`，只有 `sourceValue` 变化时调用。

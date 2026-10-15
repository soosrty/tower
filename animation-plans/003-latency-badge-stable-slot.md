# 003 — 延迟徽标固定占位，测速结果局部淡入，不再挤动节点名称

- **Status**: DONE（2026-09-27）
- **Commit**: `5672973`（加工作区未提交改动；`NodeMapOverview.swift` 在工作区只改了一行颜色映射，与本计划无关）
- **Severity**: MEDIUM
- **Category**: Missed opportunity / Cohesion（状态切换瞬移、布局跳动）
- **Estimated scope**: 1 个源文件（`Tower/Features/Subscriptions/NodeMapOverview.swift`），约 20 行；1 个源码守卫测试可能需要同步

## Problem

`NodeLatencyBadge`（`Tower/Features/Subscriptions/NodeMapOverview.swift:711-745`）有三种状态：测试中是菊花，出结果后是“123 ms / 方式”，失败是“不可达”。三者宽度各不相同，切换时既没有过渡，也没有固定占位：

```swift
// NodeMapOverview.swift:721-744 — current
Group {
    if model.latencyTestingNodeIDs.contains(node.id) {
        ProgressView()
            .controlSize(.mini)
            .frame(minWidth: 48)
    } else if let measurement = model.nodeLatencies[node.id] {
        if let milliseconds = measurement.milliseconds {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(milliseconds) ms") …
                Text(measurement.method?.rawValue ?? "") …
            }
        } else {
            Text(verbatim: measurement.isApplicable ? String(localized: "不可达") : "—") …
        }
    } else if showsUntestedState {
        Text("待测试") …
    }
}
.accessibilityElement(children: .combine)
```

它所在的两种行里，节点名称都是 `lineLimit(1)`，后面紧跟 `Spacer(minLength: 6)`：`CompactNodeRow`（第 371 行，用在订阅展开列表和地图地区列表）和 `ExpandableNodeRow`（第 463 行）。徽标宽度一变，名称的截断位置就跟着跳。

在首页地图右上角点“测速”时，几百行会各自在不同时刻从菊花变成结果。可见的每一行都会逐个“抖”一下名称，结果文字也是凭空出现的。这是首页上频率最高的批量动作之一。

## Target

- 只要徽标有内容（测试中 / 有结果 / 显示“待测试”），就占一个**最小宽度 56pt、右对齐**的槽位。菊花换成结果时，槽宽不变，名称不动。
- 如果从未测试且 `showsUntestedState == false`，保持现在的 0 宽度。这样订阅列表在没测过速时不会平白少 56pt 名称空间。代价是整批测速开始时所有行统一变一次，这个可以接受。
- 状态之间做局部透明度过渡，用 `TowerMotion.selection(reduceMotion:)`（0.16s easeOut，减弱动态时 0.14s）。
- 同一节点重测、毫秒数变化时，普通模式用 `.contentTransition(.numericText(value:))`，减弱动态模式用 `.opacity`。
- 动画必须限定在徽标内部，不能经过行或列表的事务，否则会让几百行一起做布局动画。

## Repo conventions to follow

- 动画 token：`TowerMotion.selection(reduceMotion:)`（`Tower/Design/TowerTheme.swift:58-60`）。
- 把动画限定在局部内容上的现成写法，见 `Tower/Features/Subscriptions/NodeFilterView.swift:165-169`：
  ```swift
  .animation(TowerMotion.selection(reduceMotion: reduceMotion)) { content in
      content.contentTransition(reduceMotion ? .opacity : .numericText(value: Double(includedFilteredNodeCount)))
  }
  ```
  这个带闭包的 `.animation(_:body:)` 只作用于闭包内的修饰符，不会波及父级布局。优先用它。
- 数字过渡参考 `MetricPill`（`TowerTheme.swift:192-210`）。

## Steps

1. 在 `NodeLatencyBadge` 里加 `@Environment(\.accessibilityReduceMotion) private var reduceMotion`。
2. 新增一个私有的状态键，只用来驱动过渡：
   ```swift
   private enum Phase: Equatable { case none, untested, testing, measured, failed }
   private var phase: Phase {
       if model.latencyTestingNodeIDs.contains(node.id) { return .testing }
       if let measurement = model.nodeLatencies[node.id] {
           return measurement.milliseconds == nil ? .failed : .measured
       }
       return showsUntestedState ? .untested : .none
   }
   ```
3. 把 `body` 改成 `ZStack(alignment: .trailing)`。每个分支都加 `.transition(.opacity)`；删掉菊花上的 `.frame(minWidth: 48)`；给毫秒数 `Text` 加上：
   ```swift
   .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(milliseconds)))
   ```
4. 在 `ZStack` 外依次加：
   ```swift
   .frame(minWidth: phase == .none ? 0 : 56, alignment: .trailing)
   .animation(TowerMotion.selection(reduceMotion: reduceMotion), value: phase)
   .animation(TowerMotion.selection(reduceMotion: reduceMotion), value: model.nodeLatencies[node.id]?.milliseconds)
   .accessibilityElement(children: .combine)
   ```
   这里的 `.animation(_:value:)` 挂在徽标自身上，只影响徽标子树。如果真机上发现名称的截断位置也被插值，就改用第 2 条约定里的闭包形式，把透明度过渡包进去。
5. `TowerTests/SubscriptionInteractionTests.swift:625` 用源码字符串断言 `NodeLatencyBadge(node: node, showsUntestedState: false)`。本计划**不改**调用处，这个断言应该保持通过；如果失败，说明改动越界了。

## Boundaries

- 不要改 `CompactNodeRow` / `ExpandableNodeRow` 的布局、字体或间距，不要改测速逻辑、`NodeRuntimeBatch` 的批量发布，也不要改地图着色。
- 不要给整行或 `LazyVStack` 加 `.animation`。
- 不要用 `withAnimation` 去包 `AppModel` 里测速结果的写入：模型层保持无动画。
- 如果 `NodeLatencyBadge` 的结构和上面的引用不同，停下来报告。

## Verification

- **Mechanical**：TowerTests 全部通过（命令见 `docs/DEVELOPMENT.md`）。
- **Feel check**（模拟器可以做初步检查，最终需要真机，见 `CLAUDE.md`「改动验收」）：
  - 导入一个约 200 节点的订阅，展开订阅卡片，点地图右上角“测速”。开始的瞬间，所有可见行的名称统一变短一次；之后结果陆续到达，**名称截断位置不再变化**，结果文字淡入。
  - 再测一次：毫秒数按位滚动变化，不是整块替换。
  - 用 Simulator 的 Debug → Slow Animations 放慢观察：列表行高不插值，只有徽标内部在变。
  - 打开“减弱动态效果”：只有淡入淡出，没有数字滚动。
  - 本地节点卡片（`ExpandableNodeRow`，显示“待测试”）从“待测试”到菊花再到结果，宽度保持稳定。
- **Done when**：批量测速过程中，同一行名称的截断位置只在测速开始时变一次。

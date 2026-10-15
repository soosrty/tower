# 008 — 拖动期间冻结标签排版，并去掉逐个标签的阴影

- **Status**: DONE（2026-09-27）
- **Commit**: `1eef4f2`
- **Severity**: MEDIUM
- **Category**: Performance
- **Estimated scope**: `WorldDotMapView.swift`

## Problem

拖动时每一帧 `onChanged` 都会写入 `@State viewport`，整个 `GeometryReader` 主体随之重算（`WorldDotMapView.swift:343-366`）：`LabelPlanner.plan` 做两两碰撞检测，每个标记最多试 8 个候选位置；`markersForLabels` 在每个标记内部排序；`labelsForPresentation` 每个标签都用 `first(where:)` 查找，也是两两比较；此外每个国家名标签带一层 `.shadow`（`:540` 附近），每帧都要做一次离屏渲染。

## Target

- 手势开始（`takeOverViewport`）时复用居中动画已有的 `FrozenLabel` 快照（`captureLabelSnapshot`）；标签只跟着平移和缩放移动，静止后（`settleRasterIfIdle`）再重新排版一次。
- `labelsForPresentation` 改用字典查找。
- 标签去掉 `.shadow`，未选中的标签改用 0.5pt 的 `Color.primary.opacity(0.08)` 细描边；选中标签保留原有的 0.75pt 描边。

## Verification

- 真机：放大后拖动时，标签跟手移动，不闪也不换位置；松手停下后，标签一次性排好。
- 需要确认占比时，用 Instruments 的 SwiftUI / Animation Hitches 模板录一次拖动。

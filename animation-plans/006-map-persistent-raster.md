# 006 — 地图只保留一张底图：拖动和动画期间不换渲染器、不重画

- **Status**: DONE（2026-09-27，与 007、008 同批实施）
- **Commit**: `1eef4f2`
- **Severity**: HIGH
- **Category**: Performance
- **Estimated scope**: `Tower/Features/Subscriptions/WorldDotMapView.swift`，`TowerTests/WorldDotMapTests.swift`

## Problem

`RenderPlanner.usesDetailCanvas`（`WorldDotMapView.swift:1006-1013`）让放大后的地图在手指按下时（`takeOverViewport` 把 `isManipulatingViewport` 设为 true）从清晰的 `WorldDotDetailCanvas` 切换到 1 倍的 `WorldDotCanvas`，松手后再切回来：

```swift
static func usesDetailCanvas(detailLevel:isManipulatingViewport:isRecenteringSelection _:) -> Bool {
    detailLevel != .overview && !isManipulatingViewport
}
```

每次切换都换了视图身份，整张图要重画一遍并执行 `drawingGroup`。松手时要重画整个世界的细节图层：9,014 个陆地格，4.2 倍时每格 4 个小点，约 3.6 万个；画成约 1,520×995pt（按 3 倍屏约 13.6M 像素、约 54MB）的离屏纹理，而且正好发生在松手滑行开始的那一帧。拖动期间显示的是放大了 1.8–4.2 倍的 1 倍画布，点阵发糊。

## Target

- 只用 `WorldDotDetailCanvas` 一个渲染器。1 倍时细分为 1，画法与原来的总览画布完全一样；删除 `WorldDotCanvas`。
- 底图的输入（`rasterScale`、覆盖格、延迟色）存进 `@State raster`，只在“静止”时更新：没有手势、`viewportAnimationToken == nil`、`!isRecenteringSelection`。平移和缩放期间继续用同一张缓存图，只做变换；缩放时暂时会略软，停下后重画一次，这时画面已经不动。
- 以下时机调用 `settleRasterIfIdle()`：视口动画结束、居中动画结束、减弱动态的即时路径、着色任务完成、尺寸变化。

## Verification

- `WorldDotMapTests` 通过：`RenderPlanner.rasterScale` 在移动时保持原值，静止时跟随视口。
- 真机：放大到最大后反复拖动、甩动，按下和松手都不应有停顿，拖动时点阵保持清晰。

# 007 — 选中国家单独成层：点国家不再重画整张世界图

- **Status**: DONE（2026-09-27）
- **Commit**: `1eef4f2`
- **Severity**: HIGH
- **Category**: Performance
- **Estimated scope**: `WorldDotMapView.swift`

## Problem

选中国家会改变 `WorldDotPaint.selectedCells`（`WorldDotMapView.swift:1586-1592`，由 `:499-512` 的后台任务计算），它是整张底图 `Equatable` 输入的一部分。所以每次点国家，都会在 0.38 秒的居中弹簧动画中途整张重画一次。在总览时点国家，缩放还会从 1 变成 1.8（`centeredOnSelection`），动画一开始又要换渲染器、重画一次。

## Target

- 底图不再接收 `selectedCells`，选中格按普通覆盖格画。
- 新增 `WorldDotSelectionCanvas`：只画选中国家的格子，使用选中样式（直径 0.9 格，选中色不透明，能完全盖住下面 0.72 格的普通覆盖点）。画布的外框只覆盖选中格的边界矩形（`WorldDotPaint.selectionBounds`，按格计算），按 `raster.scale` 光栅化，放在与底图相同的变换层里。
- 选中变化只重画这一小层；新缩放下的底图重画由 006 推迟到动画结束。

## Verification

- 真机：在总览和放大两种状态下各点几个国家，居中动画全程顺滑；选中国家颜色加深、点更密，和改动前一致。

# iOS 16 build

This fork's `ios16` branch tracks the upstream source while keeping an iOS 16.0 deployment target.

## Current upstream baseline

- Repository: https://github.com/pengchujin/tower
- Commit: `20f67e914f74640b5210ec0de1da21e3978d1965`
- Source version: 1.0.30 (69)
- No application data, API tokens, signing certificates, or provisioning profiles are included in the repository.

## Compatibility changes

- `AppModel` uses Combine `ObservableObject`; observed stored state is `@Published`, while caches and operation handles remain non-published.
- SwiftUI injection uses `StateObject` / `EnvironmentObject`.
- iOS 17-only empty states, change notifications, feedback and animation APIs have iOS 16-compatible implementations.
- The subscription page keeps the upstream map and ordinary `VStack`, but does not install `.refreshable`. This retains the layout/refresh-gesture changes from the build that the device user reported as fixing scroll rebound.
- iOS 16 map pinch zoom uses `MagnificationGesture` with the map center as anchor.
- Native animation completion is used on iOS 17+. iOS 16 uses an approximate 0.5-second cleanup delay with existing session-token guards.

## Build and installation

Use `.github/workflows/build-ios16.yml`. It produces a physical-device arm64 unsigned IPA with `MinimumOSVersion` checked during packaging.

An unsigned IPA requires an external signing/sideloading tool before installation. GitHub credentials are not Apple signing credentials. Features requiring Apple capabilities (for example iCloud) also depend on the entitlements and provisioning profile used for signing.

## Verification boundaries

A successful device build and an inspected IPA establish build/packaging compatibility, not full iOS 16 runtime correctness. Device scrolling, import/export, map interaction and signing-capability behavior need device validation. No physical-device or iOS 16 simulator result is implied by a successful GitHub Actions build.

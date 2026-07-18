# LeCodesSDK (iOS)

Binary distribution of the LeCodes iOS SDK for Swift Package Manager.

## Install

In Xcode: **File ▸ Add Package Dependencies…** and enter:

```
https://github.com/letary/lecodes-ios-sdk.git
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/letary/lecodes-ios-sdk.git", from: "1.0.0")
```

## Variants

Add exactly **one** product to your target:

- **LeCodesSDK-full** — everything: 3D scenes & AR (CreatorGL/filament, Jolt physics) + the 2D engine.
- **LeCodesSDK-3d** — UI + 3D scenes & AR (Jolt physics included), without the 2D engine.
- **LeCodesSDK-2d** — UI + the 2D engine (physics included), without 3D/AR — ~19 MB/slice smaller.
- **LeCodesSDK-core** — UI only.

All vend the same module:

```swift
import LeCodesSDK
```

## Resources (full and 3d variants)

The 3D-bearing variants need filament resources that SwiftPM can't deliver for a
static framework. Download **LeCodesSDKResources.bundle** from the release assets
and add it to your app target (**Copy Bundle Resources**). The 2d and core
variants need none.

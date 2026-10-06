# LeCodes (iOS)

The LeCodes iOS SDK as a Swift package: the Swift layer (the host over the runtime, the UIKit
renderer, the AnyCanvas painter) as sources, the engine (the runtime, Filament, Jolt, the 2D engine…)
as a binary target the manifest downloads. Built by `lecodes app` shells; any iOS app can embed it.

## Install

In Xcode: **File ▸ Add Package Dependencies…** and enter `https://github.com/letary/lecodes-ios-sdk.git`.
Or in `Package.swift`:

```swift
.package(url: "https://github.com/letary/lecodes-ios-sdk.git", exact: "2.0.8")
```

## Variants

A version is four tags of the same sources over four engines; pick the tag:

| tag | engine |
|---|---|
| `2.0.8` | **full** — 3D scenes & AR (Filament, Jolt physics, navigation, networking, audio) + the 2D engine |
| `2.0.8-3d` | 3D scenes & AR without the 2D engine |
| `2.0.8-2d` | the 2D engine (Box2D physics) without 3D / AR |
| `2.0.8-core` | UI only |

Products: `LeCodes` (the SDK — `LeCodesEngine`, `LeCodesView`, `LeCodesViewController`),
`LeCodesAR` (ARKit behind the 3D scenes; full / 3d) and `LeCodesHRTF` (binaural audio filters, only
where `engine.useHrtf()` is called). `LeCodesCore` and `LeCodesUIKit` are the layers under it.

```swift
import LeCodes
```

The 3D variants' resources (the ubershader archive, the IBL, the materials) ride inside the package as
SwiftPM resources — nothing to add to the app target.

## 1.x

Releases up to 1.7.0 were four binary-only xcframeworks of the whole SDK (`LeCodesSDK-<variant>`,
module `LeCodesSDK`); their tags stay. 2.x is a new contract (the runtime set's major): a 1.x shell
keeps its pin until `lecodes app update` moves it.

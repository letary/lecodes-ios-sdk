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

- **LeCodesSDK-full** — CreatorGL + filament (3D scenes & AR).
- **LeCodesSDK-core** — UI only, ~15 MB smaller (no 3D/AR).

Both vend the same module:

```swift
import LeCodesSDK
```

## Resources (full variant only)

The full variant needs filament resources that SwiftPM can't deliver for a static
framework. Download **LeCodesSDKResources.bundle** from the release assets and add
it to your app target (**Copy Bundle Resources**). The core variant needs none.

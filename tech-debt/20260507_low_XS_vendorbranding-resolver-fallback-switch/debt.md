---
title: VendorBrandingResolver has a hardcoded fallback switch for pre-registry state
date: 2026-05-07
criticality: low
size: XS
---

## Problem

`VendorBrandingResolver.brand(for:)` in `App/VendorBranding.swift` first
consults `VendorRegistry`, then falls through to a hardcoded switch:

```swift
static func brand(for vendor: Vendor) -> AIUsagesTrackersLib.VendorBranding? {
    if let bundle = VendorRegistry.bundle(for: vendor) {
        return bundle.branding
    }
    switch vendor {
    case .claude:  return ClaudeCodePlugin.branding
    case .codex:   return CodexPlugin.branding
    case .copilot: return CopilotCLIPlugin.branding
    default:       return nil
    }
}
```

Adding a fourth vendor requires editing both `AppDelegate` (to register it)
and this switch (for the UI to render it when the registry is empty). The
comment in the code says the fallback handles "the UI before the registry is
populated (e.g. in tests)" — but the conformance tests populate the registry
themselves, and `AppDelegate` calls `VendorRegistry.resetForTesting()` on
startup anyway, meaning this path is only ever exercised in unexpected code
paths.

## Impact

- **Maintainability**: low — the switch is tiny, but it is a second place
  that must be edited per vendor.
- **AI code generation quality**: agents adding a vendor following
  `docs/VENDOR-PLUGIN-CONTRACT.md` will miss this switch and produce an
  invisible vendor icon in the UI without any compile-time error.
- **Bug/regression risk**: low — the fallback is defensive code; the main
  path goes through the registry.

## Affected files / areas

- `AIUsagesTrackers/Sources/App/VendorBranding.swift` — `VendorBrandingResolver.brand(for:)` fallback switch

## Refactoring paths

1. Remove the fallback switch entirely. If the registry is empty, `brand(for:)`
   returns `nil` and the UI shows the text-initial fallback (already
   implemented in `VendorIconView`).

2. Alternatively, if a pre-registry-population fallback is genuinely needed
   (e.g. for a SwiftUI preview), introduce a `static let allKnownBrandings:
   [Vendor: VendorBranding]` dictionary derived from the plugin static
   properties at compile time, instead of a switch.

3. Update `VendorBrandingTests` to reflect whichever approach is chosen.

## Acceptance criteria

- [ ] No `switch vendor` exists inside `VendorBrandingResolver`.
- [ ] Adding a new vendor requires no edit to `VendorBranding.swift`.
- [ ] `swift test` passes.

## Additional context

Introduced in vendor-plugin-framework step 5 when `App/VendorBranding.swift`
was refactored to separate the `VendorBrandingResolver` enum from the lib's
`VendorBranding` value type. The switch was added as a defensive fallback for
the startup window before `AppDelegate.applicationDidFinishLaunching` calls
the plugin registration methods.

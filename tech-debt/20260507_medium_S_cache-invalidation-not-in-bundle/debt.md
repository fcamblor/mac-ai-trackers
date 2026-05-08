---
title: Cache-invalidation hooks bypass VendorBundle and live in AppDelegate
date: 2026-05-07
criticality: medium
size: S
---

## Problem

`CodexConnector.invalidateEmailCache()` and
`CopilotConnector.invalidateLoginCache()` are called from `AppDelegate`'s
active-account monitor callbacks:

```swift
let codexMonitor = CodexActiveAccountMonitor(
    onActiveAccountChanged: { [weak codexConnector, weak poller] _ in
        await codexConnector?.invalidateEmailCache()   // <-- concrete type
        await poller?.pollOnce(force: true)
    }
)
```

`AppDelegate` captures the concrete connector type (`CodexConnector`) to call
a vendor-specific method. The `VendorBundle` interface does not express cache
invalidation at all. As a consequence, a future vendor whose connector needs
a similar cache-clear-on-account-switch cannot follow the contract alone —
it must also edit `AppDelegate`.

This is a direct violation of the contract's promise:
> "A new assistant can be onboarded by adding files under predictable paths
> plus one registry line — no edits to `AppDelegate`, `Loggers`, or other
> shared subsystems beyond their declared plugin points."

## Impact

- **Maintainability**: every vendor with a cached identity must be wired
  individually in `AppDelegate`, growing the wiring section each time.
- **AI code generation quality**: the pattern reinforces the old "name each
  vendor explicitly in AppDelegate" approach rather than the registry-driven
  approach the contract mandates.
- **Bug/regression risk**: low today (only two vendors need it); medium as
  the vendor count grows, because each missed wiring silently keeps a stale
  account in the UI.

## Affected files / areas

- `AIUsagesTrackers/Sources/App/AppDelegate.swift` — monitor callback closures (lines ~104, ~110)
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/CodexConnector.swift` — `invalidateEmailCache()`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/CopilotConnector.swift` — `invalidateLoginCache()`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Plugins/VendorBundle.swift` — no invalidation hook today

## Refactoring paths

Two viable approaches:

### Option A — `onAccountChanged` hook in `VendorBundle`

Add an optional async closure to `VendorBundle`:

```swift
public let onAccountChanged: ((@Sendable () async -> Void))?
```

Each plugin's `register()` factory populates it with the connector's
invalidation call. `AppDelegate` fires `bundle.onAccountChanged?()` inside
the generic monitor callback before calling `poller.pollOnce(force: true)`.
The monitor callback then becomes uniform across all vendors.

### Option B — `CacheInvalidating` protocol on the connector

Define:

```swift
public protocol CacheInvalidating: AnyObject, Sendable {
    func invalidateCache() async
}
```

Conforming connectors implement it; the `VendorBundle` exposes `(any CacheInvalidating)?`.
`AppDelegate` calls `bundle.connector as? any CacheInvalidating` or stores
it in the bundle directly.

Option A is simpler and avoids an extra protocol. Option B is more explicit
and testable in isolation.

1. Choose an approach (A recommended).
2. Add the hook / protocol to `VendorBundle`.
3. Populate it in `CodexPlugin.register()` and `CopilotCLIPlugin.register()`.
4. Simplify the `AppDelegate` monitor callback to the generic form:
   ```swift
   onActiveAccountChanged: { [weak poller, bundle] _ in
       await bundle.onAccountChanged?()
       await poller?.pollOnce(force: true)
   }
   ```
5. Remove the `[weak codexConnector]` / `[weak copilotConnector]` captures
   from `AppDelegate`.
6. Update tests for the affected plugin `register()` functions.

## Acceptance criteria

- [ ] `AppDelegate` does not directly reference `CodexConnector` or
  `CopilotConnector` for cache invalidation.
- [ ] Adding a new vendor with a cache-to-invalidate requires only changes
  to the vendor's plugin file (not `AppDelegate`).
- [ ] `swift test` passes.

## Additional context

Introduced in vendor-plugin-framework step 5. The cycle between the poller
(which needs the connector list) and the monitor callbacks (which reference
specific connectors) forced AppDelegate to stay aware of concrete types.
Resolving this debt requires the hook/protocol approach above; it does not
require rearchitecting the poller/monitor dependency order.

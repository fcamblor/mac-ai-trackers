# Swift menu bar UI

Lessons learned while trying to render per-segment colored indicators in the menu bar. Read this before touching `AppDelegate.swift` or `MenuBarLabelRenderer.swift`.

## Do not use `MenuBarExtra` for anything beyond a single monochrome label

SwiftUI's `MenuBarExtra` is attractive but has hard limitations that silently break real use cases:

1. **All SwiftUI content in its `label:` is rendered as a template image.** Any color set via `foregroundStyle`, `foregroundColor`, `AttributedString` with `ForegroundColorAttribute`, or `NSAttributedString` bridged through `\.appKit` is stripped. macOS tints the result monochrome (white when highlighted, black/white otherwise).
2. **Mixed `HStack` layouts (e.g. `Image` + `Text`, or `ForEach` with multiple children per iteration) silently truncate after the first child.** A second segment will simply not render, with no warning or log.
3. **`Text(Image(nsImage:))` concatenation does not preserve `isTemplate = false`.** Even if the underlying `NSImage` is non-template, SwiftUI templates it when wrapping into a `Text`.

If you need per-element colors, multiple segments, or any non-trivial composition, **drop `MenuBarExtra` and use `NSStatusItem` directly** via an `NSApplicationDelegateAdaptor`-registered `AppDelegate`.

## The NSStatusItem pattern

See `Sources/App/AppDelegate.swift` for the reference implementation. Key points:

- Own a single `NSStatusItem` created with `NSStatusItem.variableLength`.
- Host the popover content with `NSPopover` + `NSHostingController(rootView: <SwiftUI view>)`. Behavior `.transient` so it closes on outside click.
- Wire `button.target` / `button.action` to a toggle method that calls `popover.show(relativeTo:of:preferredEdge:)` or `performClose(_:)`.
- Rasterise the label into an `NSImage` via `NSImage.lockFocus()` + `NSAttributedString.draw(at:)`, and set `image.isTemplate = false` before assigning to `button.image`.

Without `isTemplate = false`, macOS tints the image monochrome and all color work is lost.

## Menu bar appearance ≠ app appearance

The menu bar has its own appearance, driven by the wallpaper behind it (wallpaper tinting), **not** by the system's light/dark mode. A user can be in light mode with a dark wallpaper; the menu bar text is white, but `NSApp.effectiveAppearance` still reports `aqua`.

For correct text color in a rasterised label:

1. Read `statusItem.button?.effectiveAppearance` — this tracks the menu bar.
2. Resolve with `.bestMatch(from: [.darkAqua, .aqua])` to decide white vs black.
3. Observe changes with `button.observe(\.effectiveAppearance, options: [.new])` and re-render when it fires (wallpaper can change, reduce-transparency can toggle).

Never use `NSColor.labelColor` for rasterised menu bar text: it resolves against the app's appearance at draw time and will be wrong whenever the menu bar is tinted differently.

## Rasterising with `lockFocus`

```swift
let image = NSImage(size: size)
image.lockFocus()
attributed.draw(at: point)
image.unlockFocus()
image.isTemplate = false
```

- Size the image from `NSAttributedString.size()` plus horizontal padding, and use the menu bar's default height (18pt matches `menuBarFont(ofSize: 0)`).
- `NSFont` is not `Sendable` — mark any enum/class holding `NSFont` constants with `@MainActor` to satisfy strict concurrency.

## Observing `@Observable` store changes from AppKit

`withObservationTracking` fires exactly once per registration. To keep the status item mirroring the store, re-arm tracking inside the `onChange` callback:

```swift
private func trackStoreChanges(store: UsageStore) {
    withObservationTracking {
        _ = store.menuBarSegments
        _ = store.menuBarText
    } onChange: { [weak self] in
        Task { @MainActor in
            guard let self else { return }
            self.refreshStatusItemImage()
            self.trackStoreChanges(store: store)
        }
    }
}
```

Forgetting to re-arm means the status item freezes after the first change.

## Per-tier colors

`ConsumptionTier` exposes both `color: Color` (SwiftUI, for the popover) and `nsColor: NSColor` (AppKit, for rasterising). Use `systemGreen`/`systemBlue`/... rather than `.green`/`.blue` so the hues match SwiftUI system colors and adapt across appearances.

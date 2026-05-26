# Swift menu bar UI

Lessons learned while building the chip-based menu bar label. Read this before touching the status-item rendering path.

## Chips, not flat segments

The menu bar label is a list of **chips**. Each chip is a pill drawn behind a
sub-list of **segments**:

- A chip owns vendor-level chrome: vendor icon (optional), outage warning
  badge (optional), and the pill background colour.
- A chip's segments share the chip's pill — they are rendered inside it,
  separated by a thin space.
- A chip is constrained to hold at least one segment; each segment must
  declare at least one visible element (dot, letter, percent, or reset
  countdown). Both invariants are enforced at decode time.

The pill colour is picked from `ChipBackground` (three curated options:
`paper`, `slate`, `system`). Anything more permissive — per-chip colours,
gradients, free-form hex — would defeat the legibility guarantees of the
tier colour palette painted inside the pill.

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

## Pill rasterisation

Each chip's pill is drawn with `NSBezierPath(roundedRect:xRadius:yRadius:)`
on a single `NSImage` covering the whole label. The chip text is drawn on
top of the pill in the same `lockFocus` pass, so there is no second
compositing step and the bitmap stays sharp at integer pixel boundaries.

Two consequences:

1. The pill's text colour is fixed by the chip background (dark on `paper`,
   light on `slate`), not by the menu bar appearance. Wallpaper tinting no
   longer drives the text colour at all once a chip is involved.
2. The dot needs no stroke — the pill already provides a guaranteed
   contrast against the tier fill. Stripping the stroke also lets us drop
   the `colorizedAttributes` text outline that the pre-chip renderer used.

## Pacing colour cycle (debug)

A debug-only affordance cycles every visible chip segment's text and dot
through `ConsumptionTier.allCases` at 1 Hz, so the contrast between each
tier hue and the chosen `ChipBackground` can be QA'd live. The renderer
takes a `tierOverride: ConsumptionTier?` parameter that forces the dot fill
and the text colour when non-nil; production callers always pass `nil`.

The override is stored in `MenuBarRenderKey` so the dedup logic naturally
batches identical overrides and only repaints when the cycle ticks.

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
        _ = store.menuBarChips
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

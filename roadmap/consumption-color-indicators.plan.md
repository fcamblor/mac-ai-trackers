---
title: Consumption color indicators
date: 2026-04-18
---

# Implementation plan — Consumption color indicators

## Overall approach

Introduce a pure function `consumptionColor(ratio:)` in the library target that maps a consumption ratio (`actual / theoretical`) to one of six severity tiers. Wire it into two rendering paths: (1) `GaugeBar` receives the ratio as a new parameter and replaces its hard-coded color thresholds, and (2) `UsageStore` exposes a `menuBarColor` property computed from the worst-severity metric currently displayed in the menubar label. The menubar `Text` label applies this color via `.foregroundStyle`. All color logic lives in the library so tests can exercise it without importing SwiftUI (using a `ConsumptionTier` enum that the view layer maps to `Color`).

## Impacted areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Helpers/UsageComputations.swift` — new `ConsumptionTier` enum and `consumptionTier(ratio:)` function
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift` — new `menuBarTier: ConsumptionTier?` published property, computed alongside `menuBarText`
- `AIUsagesTrackers/Sources/App/Views/GaugeBar.swift` — replace hard-coded `fillColor` with a `ConsumptionTier`-based color; accept tier as input
- `AIUsagesTrackers/Sources/App/Views/TimeWindowMetricRow.swift` — compute consumption ratio and tier, pass to `GaugeBar`
- `AIUsagesTrackers/Sources/App/AIUsagesTrackersApp.swift` — apply `menuBarTier` color to the menubar label
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/` — new test file for tier logic, extended store tests for `menuBarTier`

## Phases and commits

### Phase 1 — Domain model: ConsumptionTier enum and mapping function

**Goal**: Provide a testable, pure mapping from consumption ratio to severity tier in the library target.

#### Commit 1 — `feat(model): add ConsumptionTier enum and consumptionTier(ratio:) function`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Helpers/UsageComputations.swift`
- Changes:
  - Add a `public enum ConsumptionTier: Comparable, Sendable, CaseIterable` with six cases ordered by severity: `comfortable` (< 0.7), `onTrack` ([0.7, 0.9)), `approaching` ([0.9, 1.0)), `over` ([1.0, 1.2)), `critical` ([1.2, 1.6)), `exhausted` (>= 1.6).
  - Add `public func consumptionTier(ratio: Double) -> ConsumptionTier` that maps a ratio to the correct case.
  - Add `public func consumptionRatio(actualPercent: UsagePercent, theoreticalFraction: Double) -> Double?` — returns `nil` when `theoreticalFraction <= 0` (window not started or unparseable), otherwise returns `Double(actualPercent.rawValue) / (theoreticalFraction * 100.0)`.
  - Named constants for each threshold (`comfortableUpperBound = 0.7`, etc.) as private static members.
- Risk: The ratio can exceed 1.0 legitimately (user consumed more than the theoretical pace). Edge case: `theoreticalFraction == 0` at window start — return `nil` to avoid division by zero; the caller uses a neutral color.

#### Commit 2 — `test(model): cover ConsumptionTier mapping and ratio computation`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/ConsumptionTierTests.swift` (new)
- Changes:
  - Test `consumptionTier(ratio:)` at every boundary: 0.0, 0.69, 0.7, 0.89, 0.9, 0.99, 1.0, 1.19, 1.2, 1.59, 1.6, 2.0, negative values.
  - Test `consumptionRatio(actualPercent:theoreticalFraction:)`: normal case, zero theoretical (returns nil), edge at exactly 0.
  - Test `Comparable` ordering: `comfortable < onTrack < ... < exhausted`.
- Risk: None.

### Phase 2 — Progress bar coloring in the popover

**Goal**: Replace GaugeBar's hard-coded color thresholds with ratio-based tier coloring.

#### Commit 3 — `feat(view): color GaugeBar fill by consumption tier`
- Files:
  - `AIUsagesTrackers/Sources/App/Views/GaugeBar.swift`
  - `AIUsagesTrackers/Sources/App/Views/TimeWindowMetricRow.swift`
- Changes:
  - **GaugeBar**: Replace the `fillColor` computed property and remove the existing 0.75/0.9 threshold logic. Add a new stored property `tier: ConsumptionTier?`. Compute `fillColor` from the tier: `comfortable` -> `.green`, `onTrack` -> `.blue`, `approaching` -> `.yellow`, `over` -> `.orange`, `critical` -> `.red`, `exhausted` -> `.black`. When tier is `nil` (window not started), fall back to `.accentColor`.
  - **TimeWindowMetricRow**: Compute `theoretical = theoreticalFraction(resetAt:windowDuration:now:)`, then `ratio = consumptionRatio(actualPercent:theoreticalFraction:)`, then `tier = ratio.map(consumptionTier)`. Pass `tier` to `GaugeBar(actual:theoretical:tier:)`.
- Risk: At window start (`theoretical ~= 0`), ratio is `nil` and color falls back to accent — this is correct since there is no meaningful ratio yet.

### Phase 3 — Menubar badge coloring

**Goal**: Make the menubar label text color reflect the worst consumption tier among displayed metrics.

#### Commit 4 — `feat(store): expose menuBarTier from UsageStore`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift`
- Changes:
  - Add `public private(set) var menuBarTier: ConsumptionTier? = nil` alongside `menuBarText`.
  - In `format(file:)`, after building segments, also compute the tier for each displayed time-window metric (same `menuBarMetricNames` filter). For each, call `consumptionRatio` then `consumptionTier`. Take the `max()` (worst severity, thanks to `Comparable`). Store the result in a local and return it alongside the text via a `(String, ConsumptionTier?)` tuple (refactor `format` return type).
  - Update `handleNewData` and `refreshMenuBarText` to set both `menuBarText` and `menuBarTier` from the tuple.
  - On decode error, reset `menuBarTier = nil`.
- Risk: The `Comparable` ordering of `ConsumptionTier` must match severity (comfortable < exhausted). Verified in Phase 1 tests.

#### Commit 5 — `feat(app): apply menuBarTier color to menubar label`
- Files: `AIUsagesTrackers/Sources/App/AIUsagesTrackersApp.swift`
- Changes:
  - Import a small SwiftUI extension (in a new file or inline) that maps `ConsumptionTier` to `Color`. This extension lives in the App target since `Color` is a SwiftUI type and the library target does not import SwiftUI.
  - In the `label:` closure, apply `.foregroundStyle(tierColor)` to the `Text`, where `tierColor` is derived from `usageStore.menuBarTier`. When `nil`, use `.primary` (default system color).
- Risk: Menu bar text color must remain legible against both light and dark menu bars. SwiftUI system colors (`.green`, `.blue`, `.yellow`, `.orange`, `.red`) adapt automatically. For the `exhausted` tier (black), use `.primary` with maximum emphasis or a very dark gray that remains visible in dark mode — verify manually. Alternatively, map `exhausted` to a deep red or use `.secondary` for dark mode safety. This needs visual validation.

### Phase 4 — ConsumptionTier-to-Color mapping (shared App-level extension)

**Goal**: Single source of truth for tier-to-Color mapping used by both GaugeBar and the menubar label.

#### Commit 6 — `refactor(view): extract ConsumptionTier color extension`
- Files: `AIUsagesTrackers/Sources/App/Views/ConsumptionTierColor.swift` (new)
- Changes:
  - Move the `ConsumptionTier -> Color` mapping into a dedicated extension file: `extension ConsumptionTier { var color: Color { ... } }`.
  - Both `GaugeBar` and `AIUsagesTrackersApp` use `.color` instead of inline switches.
  - For the `exhausted` tier, use `Color(NSColor.labelColor)` — this is the system's strongest text color and adapts to light/dark mode while signaling maximum severity (effectively black in light mode, white in dark mode). This avoids the legibility risk of a literal `.black`.
- Risk: Minor — purely a refactor to deduplicate the switch. Must compile-check that GaugeBar and app entry point both resolve the extension.

### Phase 5 — Store and integration tests

**Goal**: Full test coverage for `menuBarTier` computation and color consistency.

#### Commit 7 — `test(store): cover menuBarTier across consumption scenarios`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes:
  - New test: feed a JSON payload where the active account has a session metric at 80% usage with 50% of the window elapsed (ratio 1.6 -> `exhausted`). Assert `menuBarTier == .exhausted`.
  - New test: two metrics displayed (session + weekly) with different tiers. Assert `menuBarTier` equals the worse of the two.
  - New test: metric at window start (theoretical ~= 0). Assert `menuBarTier == nil`.
  - New test: only pay-as-you-go metrics, no time-window. Assert `menuBarTier == nil`.
  - New test: decode error resets `menuBarTier` to nil.
  - New test: countdown refresh updates `menuBarTier` as time passes (use `MutableClock` to advance time and shift the theoretical fraction).
- Risk: Tests need a `FixedClock` at a specific point within the window to produce deterministic ratios. Reuse the existing `FixedClock` and `MutableClock` test doubles.

#### Commit 8 — `chore(roadmap): close consumption-color-indicators epic`
- Files: `roadmap/index.md`
- Changes: flip status from `in-progress` to `done`.
- Risk: None.

## Validation

- `swift build` compiles without warnings in both library and app targets.
- `swift test` passes all existing tests plus the new ones.
- Acceptance criteria from `roadmap/consumption-color-indicators.md`:
  - Each time-window progress bar fills with the color matching its consumption ratio — verified by visual inspection and by unit-testing the tier assignment logic.
  - The menubar badge color matches the worst tier of displayed metrics — verified by `UsageStoreTests`.
  - Switching brackets (e.g. editing `usages.json`) updates colors within the auto-refresh window (<=30 seconds) — the existing file watcher + countdown timer refresh both `menuBarText` and `menuBarTier`, so color updates piggyback on the same mechanism.
  - Color scheme is consistent between menubar and popover — both use the same `ConsumptionTier.color` extension.

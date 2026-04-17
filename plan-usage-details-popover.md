# Plan — Usage details popover

**Source:** `roadmap/usage-details-popover.md`
**Layer:** 2 — Impacts

---

## L1 · Bird's-eye architecture

### 1. Popover presentation mode

Replace the current `MenuBarExtra` **menu** content (static label + Quit) with a **window-style** `MenuBarExtra` (`menuBarExtraStyle(.window)`). This gives a native popover attached to the menubar item with no `NSPopover` plumbing, while keeping the compact text label unchanged.

The window content hosts a single SwiftUI view tree rooted at a new **UsageDetailsView**.

### 2. View hierarchy (new views)

```
UsageDetailsView              ← root, scrollable, fixed max-height
 ├─ AccountCardView  ×N      ← one per VendorUsageEntry
 │   ├─ card header           (vendor icon, account email, active badge)
 │   ├─ TimeWindowMetricRow   ×M   (progress bar, %, remaining, reset date, theoretical marker)
 │   └─ PayAsYouGoMetricRow   ×P   (consumed amount + currency)
 └─ footer                    (Quit button, version)
```

All views live in a new `Sources/App/Views/` directory inside the executable target.

### 3. Store surface expansion

`UsageStore` currently exposes only `menuBarText: String`. It must additionally expose the full parsed `[VendorUsageEntry]` so the popover can render rich cards. The existing file-watcher → decode → main-actor pipeline already produces this data; it just needs to be retained instead of discarded after formatting.

No new data fetching, no new actors, no new file I/O.

### 4. Theoretical consumption indicator

Each time-window metric needs a "theoretical marker" showing the expected consumption fraction given elapsed time within the window. This is a pure computation: `elapsed / windowDuration`. The calculation belongs in a lightweight helper or computed property on the view model side — not in the model layer.

### 5. Countdown refresh

The store already refreshes every 60 s for the menubar label. The same timer keeps the popover's "remaining time" displays accurate — no additional timer needed.

### 6. Modules / targets unchanged

No new Swift package targets. All new code goes into the existing executable target (views) and library target (store expansion). The model layer (`UsageModels`, `ValueObjects`) is untouched.

---

## L2 · Detailed impacts

### 2.1 Popover presentation mode

**File:** `Sources/App/AIUsagesTrackersApp.swift`

**Changes:**
- Replace the `MenuBarExtra` content closure (currently static `Text` + `Divider` + `Quit` button) with `UsageDetailsView(store: usageStore)`.
- Append `.menuBarExtraStyle(.window)` to switch from dropdown menu to window-style popover.
- The `label:` closure (`Text(usageStore.menuBarText)`) stays unchanged — it still drives the compact menubar text.
- The Quit button moves into the `UsageDetailsView` footer, so the `Button("Quit")` block and its shutdown logic relocate from the app scene to the view. The view receives a quit closure or action binding from the app.

**Interface contract:**
```swift
// UsageDetailsView receives:
// - store: UsageStore (observable, drives all card data)
// - onQuit: () -> Void (triggers shutdown sequence)
```

### 2.2 View hierarchy — new files

All new files under `Sources/App/Views/`:

| File | View | Responsibility |
|------|------|----------------|
| `UsageDetailsView.swift` | `UsageDetailsView` | Root `ScrollView` wrapping `LazyVStack` of cards + footer. Max-height capped (~480 pt) to prevent runaway growth. |
| `AccountCardView.swift` | `AccountCardView` | One `VendorUsageEntry` rendered as a grouped card. Header shows vendor name (capitalized), account email, and an "active" pill when `isActive && multipleAccountsForVendor`. Body lists metric rows. |
| `TimeWindowMetricRow.swift` | `TimeWindowMetricRow` | Label (metric `name`), custom `GaugeBar` (actual % + theoretical marker), numeric percentage, remaining time string (`Xd Yh Zm`), next-reset date (formatted short: `Apr 21, 14:00`). |
| `PayAsYouGoMetricRow.swift` | `PayAsYouGoMetricRow` | Label (metric `name`), consumed amount formatted with currency symbol (e.g. `$12.34`). |
| `GaugeBar.swift` | `GaugeBar` | Custom `Shape`-based progress bar taking `actual: Double` (0…1) and `theoretical: Double` (0…1). Two overlapping fill layers with distinct colors; the theoretical marker rendered as a thin vertical tick. |

**Ordering of accounts in the card list:**
- Group entries by `vendor`.
- Within a vendor group: active account first, then alphabetical by `account.rawValue`.
- If only one account exists per vendor, suppress the active badge (no visual noise).

**UI design pass:**
- Use `/impeccable:shape` skill before coding to run a structured design discovery and produce a design brief (layout, spacing, typography, color tokens) that targets native macOS aesthetic (NSVisualEffectView-like vibrancy, system fonts, compact density).
- After implementation, use `/impeccable:polish` (or `/impeccable:impeccable`) to perform a final quality pass on alignment, spacing, and micro-details.

### 2.3 Store surface expansion

**File:** `Sources/AIUsagesTrackers/Store/UsageStore.swift`

**Changes:**
- Add a new published property: `public private(set) var entries: [VendorUsageEntry] = []`
- In `handleNewData(_:)`, after decoding the `UsagesFile`, set `entries = file.usages` alongside the existing `menuBarText = format(file:)`.
- In `refreshMenuBarText()`, also refresh `entries` from `lastFile` (keeps the popover countdown-fresh).
- On decode failure, reset `entries = []` alongside `menuBarText = Self.fallbackText`.

**What does NOT change:**
- `menuBarText` stays — it still drives the compact label.
- `lastFile` stays private — the views consume only `entries`.
- The `ClockProvider` protocol, watcher lifecycle, and countdown timer are untouched.

**Test impact:** `UsageStoreTests` needs new assertions verifying that `entries` is populated on successful decode and cleared on failure. Existing `menuBarText` tests remain valid.

### 2.4 Theoretical consumption indicator

**Location:** Computed at the view layer, inside `TimeWindowMetricRow`.

**Formula:**
```
elapsed = now - (resetAt - windowDuration)
theoretical = clamp(elapsed / windowDuration, 0, 1)
```
Where `now` comes from `Date()` (acceptable at the view layer — no injectable clock needed here since the 60 s store refresh already drives recomposition).

**Inputs from model:**
- `resetAt: ISODate` → `.date` gives the `Date`
- `windowDuration: DurationMinutes` → `.rawValue * 60` gives seconds

**No model changes.** The computation uses only existing associated values of `UsageMetric.timeWindow`.

### 2.5 Countdown refresh

**No changes.** The existing 60 s `countdownTask` in `UsageStore` calls `refreshMenuBarText()`, which will now also refresh `entries`. Because `UsageStore` is `@Observable`, any SwiftUI view reading `entries` automatically recomposes — the popover's remaining-time strings stay current.

### 2.6 Modules / targets unchanged

**`Package.swift`:** No changes. The new view files go into the existing `Sources/App/` directory, which is already the `executableTarget` path. The store change is in `Sources/AIUsagesTrackers/`, the existing `AIUsagesTrackersLib` target.

**No new dependencies.** All views use only SwiftUI and Foundation.

---

## Risks

| # | Risk | Mitigation |
|---|------|------------|
| R1 | `MenuBarExtra(.window)` limits styling control vs raw `NSPopover` — e.g., no programmatic show/dismiss, fixed anchor point | Acceptable: the roadmap scope only requires click-to-open / click-elsewhere-to-close, which `.window` provides natively. Escape-to-close also works out of the box. |
| R2 | Scrollable popover with 4+ accounts may clip or feel cramped | Cap max-height (~480 pt), use `ScrollView` with a reasonable frame; test with 1 and 5 accounts. |
| R3 | Theoretical consumption marker on a progress bar requires a custom `Shape` overlay — SwiftUI `ProgressView` doesn't support dual markers | Build a custom `GaugeBar` view with two fill layers (actual + theoretical). Small effort, full control. |
| R4 | Currency formatting for pay-as-you-go — raw `String` currency code needs locale-aware rendering | Use `Decimal` + `NumberFormatter` with `currencyCode` set from the metric's `currency` field. Handle unknown codes gracefully (fallback to code prefix, e.g. `USD 12.34`). |

---

## Implementation workflow

1. **Design brief** — `/impeccable:shape` to define layout, spacing, typography, and color decisions before writing view code.
2. **Store expansion** — add `entries` property + tests.
3. **Views** — implement the view tree (`GaugeBar` → metric rows → `AccountCardView` → `UsageDetailsView`), bottom-up.
4. **App integration** — swap `MenuBarExtra` content + style.
5. **Polish** — `/impeccable:polish` or `/impeccable:impeccable` for final visual refinement.

# Plan — Usage details popover

**Source:** `roadmap/usage-details-popover.md`
**Layer:** 1 — Structure

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

## Risks

| # | Risk | Mitigation |
|---|------|------------|
| R1 | `MenuBarExtra(.window)` limits styling control vs raw `NSPopover` — e.g., no programmatic show/dismiss, fixed anchor point | Acceptable: the roadmap scope only requires click-to-open / click-elsewhere-to-close, which `.window` provides natively. Escape-to-close also works out of the box. |
| R2 | Scrollable popover with 4+ accounts may clip or feel cramped | Cap max-height, use `ScrollView` with a reasonable frame; test with 1 and 5 accounts. |
| R3 | Theoretical consumption marker on a progress bar requires a custom `Shape` overlay — SwiftUI `ProgressView` doesn't support dual markers | Build a custom `GaugeBar` view with two fill layers (actual + theoretical). Small effort, full control. |

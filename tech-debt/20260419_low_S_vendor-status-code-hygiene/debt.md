---
title: Vendor status — code hygiene (dead modifier, merge coupling, dict ordering)
date: 2026-04-19
criticality: low
size: S
---

## Problem

Five small code-quality issues were identified during the vendor-status-monitor
review. None is a correctness bug, but together they make future maintenance
riskier or the UI subtly inconsistent.

1. **Dead `.buttonStyle(.plain)`** in `VendorStatusBanner` (line 49-54): the
   tap affordance is still visible when the outage has no `url`, so the banner
   looks tappable but does nothing. The chevron should be hidden (or the whole
   tap area disabled) when `url == nil`.
2. **Silent discard in `UsagesFileManager.updateIsActive`** (line 66): when the
   vendor section is missing, the call returns without logging. This masks
   schema drift from upstream connectors.
3. **Implicit merge coupling** (`UsagesFileManager.swift:89-126`): the merge
   logic rebuilds the file via the `usages` setter and relies on the setter
   preserving `outagesByVendor` — a contract that is not enforced. A future
   rewrite of the setter could drop outages silently. An `assert(result.outagesByVendor
   == existing.outagesByVendor)` or at least a comment pointing at the invariant
   is needed.
4. **Non-deterministic vendor order** in `UsagesFile.usages` getter (line 36-38):
   iterating a `Dictionary` yields a platform-dependent order. Downstream UI
   sorts its own list, but any diagnostic output or serialisation that relies on
   this getter has unstable ordering.
5. **Per-body recompute** in `UsageDetailsView` (line 29): `vendorsNeedingBanner(in:)`
   is called inside the `ScrollView` body, re-running on every view evaluation.
   Hoist to a `let` above the `ScrollView`.

## Impact

- **Maintainability**: the merge coupling is the riskiest — a refactor can
  silently drop outages.
- **AI code generation quality**: agents copying the patterns will replicate
  silent discards and dead modifiers.
- **Bug/regression risk**: low — the merge invariant is covered by an integration
  test, but only indirectly; a targeted regression could slip through.

## Affected files / areas

- `AIUsagesTrackers/Sources/App/Views/VendorStatusBanner.swift:49-54`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift:66,89-126`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/UsageModels.swift:36-38`
- `AIUsagesTrackers/Sources/App/Views/UsageDetailsView.swift:29`

## Refactoring paths

1. **Banner tap affordance**: gate the chevron on `outage.url != nil`; remove
   the `.buttonStyle(.plain)` when the banner is not tappable.
2. **updateIsActive warning**: emit `Loggers.app.log(.warning, ...)` with the
   vendor name when no section matches.
3. **Merge coupling**: add an assertion or a `// INVARIANT:` comment above the
   setter call in the merge path, linking to the preservation contract.
4. **Dict ordering**: `.sorted(by: { $0.key < $1.key })` in the `usages` getter.
5. **Banner perf**: hoist `vendorsNeedingBanner(in:)` above the `ScrollView` as
   a `let`.

## Acceptance criteria

- [ ] `VendorStatusBanner` shows no chevron and consumes no tap when `url` is nil.
- [ ] `updateIsActive` emits a warning when the vendor section is missing, with
  a test verifying the warning is logged.
- [ ] The merge path has an explicit assertion or clearly-written invariant
  comment referencing outage preservation.
- [ ] `UsagesFile.usages` getter returns a deterministic order; the assertion
  is covered by a test.
- [ ] `UsageDetailsView` computes `vendorsNeedingBanner(in:)` at most once per
  body evaluation.

## Additional context

Findings 4-8 from the multi-axis review of vendor-status-monitor
(aggregate-apply phase, MED severity).

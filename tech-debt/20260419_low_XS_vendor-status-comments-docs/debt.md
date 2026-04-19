---
title: Vendor status — WHAT-style comments and ARCHITECTURE doc drift
date: 2026-04-19
criticality: low
size: XS
---

## Problem

The vendor-status-monitor feature shipped with 11 comments that describe the
code mechanically (WHAT) instead of explaining the reason (WHY), and with two
`docs/ARCHITECTURE.md` sections that are now out of date relative to the
schema v2 shape the feature introduces.

Comment issues:

- `UsageModels.swift` — 8 comments on the new vendor-keyed structures and the
  `usages` setter describe the operation ("iterate dict", "preserve outages")
  rather than why the code is shaped this way.
- `UsageDetailsView.swift:26-29,58-59` — 2 comments restate the loop and the
  banner placement.
- `VendorStatusBanner.swift` struct doc — describes the visual output verbatim
  instead of the invariant it enforces (one banner per vendor with any active
  outage).

Doc drift:

- `docs/ARCHITECTURE.md` — Persistence section still describes the v1 flat
  shape; the feature migrated to v2 vendor-keyed.
- `docs/ARCHITECTURE.md` — Display pipeline section does not mention outage
  surfacing via `outagesByVendor` → `VendorStatusBanner`.

## Impact

- **Maintainability**: WHAT comments drift from the code and become misleading;
  outdated architecture docs send agents down the wrong exploration path.
- **AI code generation quality**: agents reading these comments get no signal
  about design intent and may make incompatible choices.
- **Bug/regression risk**: none — purely documentary.

## Affected files / areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/UsageModels.swift` — multiple
  comment sites (see review findings 18 for exact lines).
- `AIUsagesTrackers/Sources/App/Views/UsageDetailsView.swift:26-29,58-59`
- `AIUsagesTrackers/Sources/App/Views/VendorStatusBanner.swift` — struct
  doc-comment.
- `docs/ARCHITECTURE.md` — Persistence section and Display pipeline section.

## Refactoring paths

1. **UsageModels.swift comments**: rewrite each WHAT comment into a one-line
   WHY. Delete comments that only restate the variable name or the
   doc-comment of the enclosing function.
2. **UsageDetailsView.swift comments**: rewrite or delete the 2 flagged
   comments. If the reason is "we need to compute this outside the
   ScrollView for performance", say it explicitly.
3. **VendorStatusBanner struct doc**: replace the WHAT description with the
   invariant the banner enforces (severity-tinted, one per vendor with active
   outage, tap-opens-url-when-present).
4. **docs/ARCHITECTURE.md — Persistence**: describe the v2 `schemaVersion` +
   `vendors` dict shape; mention the dual-shape decoder that accepts the
   legacy v1 on read and always writes v2.
5. **docs/ARCHITECTURE.md — Display pipeline**: add a paragraph on the outage
   flow: `UsagesFile.outagesByVendor` → `UsageStore.outagesByVendor` →
   `VendorStatusBanner` rendered inside `UsageDetailsView` per vendor.

## Acceptance criteria

- [ ] No comment in the touched files starts with "iterates", "loops",
  "creates" or similar WHAT verbs that restate the code.
- [ ] Every remaining comment in the vendor status area answers a WHY question.
- [ ] `docs/ARCHITECTURE.md` Persistence section describes the v2 shape and the
  dual-shape decoder.
- [ ] `docs/ARCHITECTURE.md` Display pipeline section describes the outage
  surfacing flow.
- [ ] `.claude/rules/markdown-authoring.md` rules are respected (English,
  no ephemeral references).

## Additional context

Findings 18-22 from the multi-axis review of vendor-status-monitor
(aggregate-apply phase, LOW severity).

---
title: Missing unit tests for vendor status value objects and decode paths
date: 2026-04-19
criticality: medium
size: S
---

## Problem

The vendor-status-monitor feature introduces several public value objects and
decode branches without dedicated unit coverage. The model-layer Codable and
merge logic is thoroughly tested (21 + 25 tests), but a set of leaf abstractions
and small branches were left uncovered.

Specifically missing:

- `OutageSeverity` and `OutageId` — no Codable round-trip, string-literal init,
  or `description` tests despite being part of the public API.
- `ISODate.init(date:)` and `.date` — no round-trip test (Date → ISODate → .date)
  and no garbage-input test.
- `UsageMetric.kind` — the three branches (`timeWindow`, `payAsYouGo`, `unknown`)
  have no direct test.
- `VendorSection` decode with a missing `"outages"` key — no assertion that it
  defaults to `[]`.
- `VendorStatusBanner.tintColor(for:)` — 5 severity branches; the color-mapping
  is pure logic but is not exercised.
- `VendorAccountEntry` ↔ `VendorUsageEntry` conversion pair — no direct
  round-trip test.
- `UsagesFile.usages` setter — no test for the new-vendor-appears case (no
  outages to preserve).
- `UsagesFileManager.updateIsActive` — no test for the no-op case (calling twice
  with the same state to verify the write is skipped).
- `UsageStore.outagesByVendor` `@Published` notification — no SwiftUI-side test
  that observers receive the change.

## Impact

- **Maintainability**: refactors in these areas can silently break behaviour.
- **AI code generation quality**: agents working on adjacent code cannot learn
  the expected behaviour of these abstractions from tests.
- **Bug/regression risk**: medium — `UsageMetric.kind` and the conversion pair
  are on the hot display path.

## Affected files / areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/ValueObjects.swift:36-45,149-199`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/UsageModels.swift:39-52,118-122,153-159,271-277`
- `AIUsagesTrackers/Sources/App/Views/VendorStatusBanner.swift:58-65`
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagesFileManagerTests.swift`
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`

## Refactoring paths

1. **Value objects** (`ValueObjectsTests.swift`): add Codable round-trip +
   string-literal init + `description` tests for `OutageSeverity` and
   `OutageId`; add `Date → ISODate → .date` round-trip + garbage-input tests
   for `ISODate`.
2. **UsageMetric.kind**: three `@Test` cases covering each branch.
3. **VendorSection**: decode `{"accounts":[]}` (no `"outages"` key) and assert
   `.outages == []`.
4. **tintColor mapping**: extract to a pure function if not already, then add a
   5-case parameterised test.
5. **Entry conversion round-trip**: `VendorAccountEntry → VendorUsageEntry →
   VendorAccountEntry` preserves all fields.
6. **usages setter new-vendor**: seed a file without vendor X, call setter to
   add vendor X accounts; assert section created and no outages.
7. **updateIsActive no-op**: call twice with the same state, assert the file
   mtime (or a write spy) shows a single write.
8. **outagesByVendor notification**: subscribe to `$outagesByVendor` and assert
   emission on outage change.

## Acceptance criteria

- [ ] Every public value object in `ValueObjects.swift` added by the
  vendor-status-monitor feature has Codable round-trip + init-from-string tests.
- [ ] `UsageMetric.kind` has one test per branch.
- [ ] `VendorSection` decode has a test for the missing `"outages"` key.
- [ ] `VendorStatusBanner.tintColor(for:)` has a parameterised test covering
  all severity cases.
- [ ] `VendorAccountEntry` ↔ `VendorUsageEntry` round-trip test exists.
- [ ] `usages` setter has a new-vendor test; `updateIsActive` has a no-op test.
- [ ] A test asserts `outagesByVendor` publishes on mutation.
- [ ] `swift build && swift test` green.

## Additional context

Findings 9-17 from the multi-axis review of vendor-status-monitor
(aggregate-apply phase, MED/LOW severity).

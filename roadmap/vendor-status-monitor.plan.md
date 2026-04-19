---
title: Vendor status monitor
date: 2026-04-19
---

# Implementation plan — Vendor status monitor

## Overall approach

The epic asks for two coupled changes: (1) restructure `usages.json` so the top
level is keyed by vendor and carries an optional per-vendor `outages` array,
and (2) surface any active incidents in the popover. We deliver the schema
evolution first as a pure data-layer change (models + persistence + merge
semantics + tests), then the UI surfacing on top of a schema that already
carries the new field. The file manager reads both the legacy flat shape
(`{"usages": [...]}`) and the new vendor-keyed shape, but always writes the
new shape — so the migration happens on the first write after upgrade and
requires no user action. Outages are owned by an upstream process: the
connector/poller path never creates or mutates the `outages` array, and the
file manager's merge preserves whatever outages the upstream writer has
written between our reads.

## Impacted areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/` — new `Outage` model
  and `OutageSeverity` value object; `UsagesFile` restructured; `VendorUsageEntry`
  unchanged semantically but reachable via a per-vendor container.
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift`
  — decode both shapes, encode only the new shape, merge semantics that
  preserve `outages` written by external processes and never introduce them
  from connector output.
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift` — expose
  outages per vendor so the popover can render them; menu bar label
  formatting unchanged.
- `AIUsagesTrackers/Sources/App/Views/UsageDetailsView.swift` — group entries
  by vendor and render a status banner per vendor with active outages
  (placement: above the first account card of each vendor).
- `AIUsagesTrackers/Sources/App/Views/VendorStatusBanner.swift` *(new)* —
  per-vendor SwiftUI view that displays one or more incidents.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/` — new test coverage for
  models, migration, merge preservation, and the store's outage exposure.
- External API to upstream writers: the new schema is the contract; the
  Claude upstream status fetcher is out of scope for this plan but is the
  concrete consumer of the `outages` schema documented below.

## Schema decisions (agreed contract with upstream)

### File root (new shape)

```json
{
  "schemaVersion": 2,
  "vendors": {
    "claude": {
      "accounts": [
        {
          "account": "user@example.com",
          "isActive": true,
          "lastAcquiredOn": "2026-04-19T12:00:00Z",
          "metrics": [ ... ]
        }
      ],
      "outages": [
        {
          "id": "abcd-1234",
          "title": "Elevated error rate on Messages API",
          "severity": "major",
          "affectedComponents": ["Claude API", "Console"],
          "status": "investigating",
          "startedAt": "2026-04-19T11:32:00Z",
          "url": "https://status.claude.com/incidents/abcd-1234"
        }
      ]
    }
  }
}
```

Keys:

- `schemaVersion` (int) — present only in the new shape; absence implies v1
  (legacy flat shape). The app uses presence to pick the decoder branch.
- `vendors` (object) — keys are vendor rawValues; values are vendor sections.
- `accounts` (array) — each entry keeps today's fields minus the now-redundant
  `vendor` key (the vendor is implicit from the parent key).
- `outages` (array, optional) — absent or empty means "no active incident".

### Outage fields

| Field | Required | Type | Notes |
|---|---|---|---|
| `id` | yes | `String` | Stable identifier from the upstream source; used for deduplication. |
| `title` | yes | `String` | Human-readable summary. |
| `severity` | yes | `String` | Open-ended (`critical`/`major`/`minor`/`maintenance`/unknown). |
| `affectedComponents` | no | `[String]` | Defaults to empty array when absent. |
| `status` | no | `String` | Incident lifecycle (`investigating`/`identified`/`monitoring`/`resolved`). |
| `startedAt` | no | `ISODate` | Optional display. |
| `url` | no | `String` | Optional link to the incident page. |

### Legacy-shape detection

If the root JSON object has a `usages` key (no `vendors`, no `schemaVersion`),
decode as v1 and lift into the new in-memory model with no outages. On the
next write we emit the v2 shape, so the migration is one-way and happens
transparently.

## Phases and commits

### Phase 1 — Models and value objects

**Goal**: define the in-memory representation of vendor sections and
outages, with round-trip Codable support for both new and legacy shapes.

#### Commit 1 — `feat(models): add Outage and OutageSeverity value objects`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/ValueObjects.swift`, `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/UsageModels.swift` *(new symbols only, no restructure yet)*, `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageModelsTests.swift`
- Changes:
  - Add `OutageSeverity` as an open-ended `RawRepresentable` struct (same
    pattern as `Vendor`), with static constants for `critical`, `major`,
    `minor`, `maintenance`; `ExpressibleByStringLiteral`, `CustomStringConvertible`,
    explicit `Codable`.
  - Add `OutageId` value object (string-backed) to avoid accidental swap
    with titles or URLs.
  - Add `Outage` struct: `id: OutageId`, `title: String`, `severity: OutageSeverity`,
    `affectedComponents: [String]` (default `[]` on decode when absent),
    `status: String?`, `startedAt: ISODate?`, `url: String?`. `Codable`, `Equatable`,
    `Sendable`, `Identifiable` via `id`.
  - Unit tests: decode a full outage JSON, decode a minimal outage (only
    required fields), round-trip encode.
- Risk: custom Codable must tolerate missing optional fields — rely on
  `decodeIfPresent` rather than default-synthesised init.

#### Commit 2 — `refactor(models): restructure UsagesFile to vendor-keyed shape`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/UsageModels.swift`, `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageModelsTests.swift`
- Changes:
  - Introduce `VendorSection` (struct): `accounts: [VendorAccountEntry]`, `outages: [Outage]`.
  - Rename `VendorUsageEntry` → `VendorAccountEntry` (no `vendor` field —
    the parent section identifies the vendor); `Identifiable` id becomes
    `account.rawValue`. Update call sites in models only.
  - Re-shape `UsagesFile` to `{ schemaVersion: Int, vendors: [Vendor: VendorSection] }`
    internally. Provide computed `allEntries: [VendorUsageEntry]` that
    flattens sections into the existing display-facing type so UI code
    consuming `entries` keeps working until Phase 3. Keep `VendorUsageEntry`
    as a view model (no longer the persisted shape).
  - Implement dual-shape `Codable`:
    - Decode: if `schemaVersion` present → decode new shape; else if
      `usages` key present → decode legacy array and fold into sections
      keyed by vendor (outages empty); else → empty file.
    - Encode: always new shape with `schemaVersion = 2`.
  - Tests: decode legacy fixture, decode new fixture, round-trip both
    through encoder and confirm legacy encoding is never emitted.
- Risk: the naming split `VendorAccountEntry` (persisted) vs
  `VendorUsageEntry` (display) is the mental-model hinge point of the
  refactor — the commit message must state this explicitly so later
  readers aren't confused by the two types.

### Phase 2 — Persistence

**Goal**: read both shapes, always write the new shape, and preserve
externally-written outages across our own updates.

#### Commit 3 — `feat(persistence): preserve outages through connector merge`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift`, `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagesFileManagerTests.swift`
- Changes:
  - Update `merge(existing:incoming:)` so it operates on `VendorSection`
    map: for each incoming account entry, update the matching section's
    accounts array (O(n+m) per `SWIFT-IO-ROBUSTNESS.md`), and leave
    `outages` untouched. Connectors never provide outages, so merging from
    their output always preserves the last-written outages.
  - `updateIsActive` operates on the target vendor's section only.
  - `read()`/`readUnsafe()` decode via the dual-shape decoder; no
    `migrate-on-read` — first write after upgrade will materialise the new
    shape via `writeUnsafe`.
  - Tests:
    - `merge_preservesOutagesFromExistingFile` — existing file has outages,
      incoming account entries do not, result keeps outages verbatim.
    - `merge_doesNotCreateOutagesFromConnectors` — connector entries can
      only populate `accounts`; no API surface accepts outages from them.
    - `read_acceptsLegacyShape` — drop a v1 JSON fixture, confirm in-memory
      representation matches the corresponding v2.
    - `writeUnsafe_alwaysEmitsV2` — after any mutation, re-reading raw JSON
      shows `schemaVersion: 2` and a `vendors` key.
- Risk: the existing `merge` handles the "errors must not erase previously
  acquired data" invariant — re-implement it on the new structure without
  regressing (test coverage for this path already exists in
  `UsagesFileManagerTests`; keep it green).

### Phase 3 — Store and UI

**Goal**: expose outages to the SwiftUI layer and render a banner per
vendor with active incidents.

#### Commit 4 — `feat(store): expose per-vendor outages`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift`, `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes:
  - Add `public private(set) var outagesByVendor: [Vendor: [Outage]] = [:]`.
  - In `handleNewData`, populate the dictionary from the decoded file
    sections; empty map on decode failure.
  - Menu bar formatting logic untouched.
  - Tests: store loads a file with outages for the active vendor, exposes
    them; store decodes legacy shape with no outages, `outagesByVendor` is
    empty; a subsequent data event clearing outages resets the dictionary.
- Risk: extending `@Observable` state means SwiftUI views already observing
  the store will recompute on outage changes — confirm no redundant
  expensive recomputations.

#### Commit 5 — `feat(popover): render vendor status banner for active outages`
- Files: `AIUsagesTrackers/Sources/App/Views/VendorStatusBanner.swift` *(new)*, `AIUsagesTrackers/Sources/App/Views/UsageDetailsView.swift`
- Changes:
  - New `VendorStatusBanner` view: coloured strip (tint by severity:
    `critical`/`major` → red, `minor` → orange, `maintenance` → blue,
    unknown → gray) with an `exclamationmark.triangle.fill` icon, the
    incident title, and a secondary line listing affected components
    (comma-joined, `lineLimit(2)`). Tapping opens the `url` in the default
    browser when present. Multiple outages stack vertically.
  - Group `sorted` entries by vendor in `UsageDetailsView`. Before the
    first account card of each vendor with non-empty outages, render
    `VendorStatusBanner`. Grouping preserves the existing sort order
    (vendor alpha, then active-first) — entries of the same vendor are
    already contiguous after `sortedForDisplay`, so a running-vendor cursor
    is enough; no second sort pass.
  - Keep the empty state path unchanged — the popover still shows
    "No usage data" when there are zero entries, even if outages exist for
    a vendor with no configured account (per epic acceptance: outages for
    vendors without accounts are ignored).
- Risk: banner interactivity must not break keyboard focus on the popover
  — use `.buttonStyle(.plain)` and `focusable(false)` consistent with the
  existing footer buttons.

### Phase 4 — Integration sanity

**Goal**: verify end-to-end that the existing auto-refresh pipeline
propagates outage changes to the UI within the 30-second contract.

#### Commit 6 — `test(integration): outage change round-trip within auto-refresh window`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift` *(new test)*, `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagesFileWatcherTests.swift` *(extend existing fixture if needed)*
- Changes:
  - Using the existing test plumbing (temp-file + real `UsagesFileWatcher`
    with a short poll interval, or a stub `FileWatching`), write an initial
    file with no outages, assert `store.outagesByVendor` is empty; write a
    file with one outage, assert the store reflects it via the
    `eventually()` helper (bounded by the `SWIFT-TESTABILITY` rule W3).
  - No production-code change; this commit purely validates the contract
    from the acceptance criteria.
- Risk: none beyond test flakiness — use `eventually()` rather than
  `Task.sleep` per `SWIFT-TESTABILITY.md`.

## Validation

Against the epic's acceptance criteria:

1. **No outages → no indicator**: covered by the empty-outages UI test and
   by the legacy-shape store test (Phase 3 commit 4, Phase 3 commit 5).
2. **At least one outage → visible incident details**: covered by the
   `VendorStatusBanner` rendering path (Phase 3 commit 5) and the
   end-to-end test (Phase 4 commit 6).
3. **Change visible within 30 s**: guaranteed by the existing
   `UsagesFileWatcher` default poll interval; integration test in
   Phase 4 asserts the store exposes outages after a file mutation.
4. **Usage metrics still render**: `UsageStore.format` is untouched;
   `UsageModelsTests` and `UsagesFileManagerTests` continue to cover the
   metric path; the legacy-shape decoder test ensures pre-existing files
   keep rendering while upstream has not yet migrated.

Runtime checks:

- `swift build` from `AIUsagesTrackers/` succeeds with no SwiftLint
  warnings (rules E1/E2/W1/W3/W4/W5 enforced).
- `swift test` is green.
- Manual sanity: run the app, let the poller write `usages.json`, confirm
  the file now opens with `schemaVersion: 2` and a `vendors` object; drop
  a hand-edited outage into the file and confirm the banner appears in
  the popover within 30 seconds.

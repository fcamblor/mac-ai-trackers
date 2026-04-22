---
title: Claude status connector
date: 2026-04-22
---

# Implementation plan — Claude status connector

## Overall approach

The `Outage` model, popover banner, and JSON schema already exist. This
epic adds the missing producer: an in-app fetcher for Claude's status
page, plugged into the existing `UsagePoller` so the global refresh
button updates outages alongside usage metrics.

We introduce a `StatusConnector` protocol parallel to `UsageConnector`,
implement `ClaudeStatusConnector` against Anthropic's public Statuspage.io
endpoint, extend `UsagePoller` to call status connectors in parallel to
usage connectors on each tick, and evolve `UsagesFileManager` with
per-vendor outage replacement semantics so a successful fetch replaces
that vendor's outages (empty list = "all clear") while a failed or
absent fetch preserves them. Outages for other vendors are never
touched — this keeps the file format open to external producers for
vendors the app has no status connector for.

## Impacted areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/` — new
  `StatusConnector` protocol and `ClaudeStatusConnector` actor.
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Scheduler/UsagePoller.swift`
  — accepts status connectors, fetches them in parallel to usage
  connectors, passes per-vendor outage results into the file manager.
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift`
  — new `update(with:outagesByVendor:)` method with per-vendor
  replacement semantics; the old `update(with:)` becomes a thin wrapper
  passing an empty map (preserves all outages, unchanged current
  behaviour).
- `AIUsagesTrackers/Sources/App/AppDelegate.swift` — one-line addition
  to register `ClaudeStatusConnector()` alongside `ClaudeCodeConnector()`.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/` — new connector tests
  with `MockURLProtocol` fixtures, poller tests covering the new
  per-vendor outage replacement paths, file manager tests covering the
  three branches (absent / empty / non-empty per vendor).

## Schema & contract

### Statuspage.io endpoint

```
GET https://status.anthropic.com/api/v2/incidents/unresolved.json
```

No auth. Response shape (only the fields we consume):

```json
{
  "incidents": [
    {
      "name": "Elevated errors on /v1/messages",
      "impact": "major",
      "created_at": "2026-04-22T10:15:00.000Z",
      "shortlink": "https://stspg.io/abc123"
    }
  ]
}
```

### Impact → severity mapping

| Statuspage `impact` | `OutageSeverity`      | Emitted? |
|---------------------|-----------------------|----------|
| `critical`          | `.critical`           | yes      |
| `major`             | `.major`              | yes      |
| `minor`             | `.minor`              | yes      |
| `maintenance`       | `.maintenance`        | yes      |
| `none`              | —                     | no (filtered) |
| anything else       | `OutageSeverity(rawValue:)` passthrough | yes |

### Per-vendor outage replacement

`UsagesFileManager.update(with entries: [VendorUsageEntry], outagesByVendor: [Vendor: [Outage]]) async`:

- Key present, list non-empty → replace all outages of that vendor in
  the file with the provided list.
- Key present, list empty → remove all outages of that vendor from the
  file ("all clear" signal).
- Key absent → outages of that vendor preserved as-is (fetch failed,
  or the app has no status connector for this vendor).

The existing `merge(existing:incoming:)` usage-merge logic is unchanged.
Outage replacement is applied on top of the merged file before the
atomic write.

## Implementation phases

### Phase 1 — Protocol and connector

1. Create `StatusConnector.swift`:
   ```swift
   public protocol StatusConnector: Sendable {
       var vendor: Vendor { get }
       func fetchOutages() async throws -> [Outage]
   }
   ```
2. Create `ClaudeStatusConnector.swift` as an actor:
   - `nonisolated let vendor: Vendor = .claude`
   - Injectable `URLSession`, `FileLogger`, base URL (defaulting to the
     real endpoint) for tests.
   - 5-second request timeout (consistent with `ClaudeCodeConnector`).
   - `fetchOutages()`:
     - GET the endpoint, parse `incidents` via `JSONDecoder` against a
       private `StatuspageIncidentsResponse` / `StatuspageIncident`
       DTO.
     - For each incident, map fields to `Outage`. Filter out `impact == "none"`.
     - Parse `shortlink` via `URL(string:)`; if parsing fails, set
       `href: nil` rather than throwing (incidents without a valid URL
       still matter).
     - Non-2xx HTTP, network error, or decoder error → `throw
       StatusConnectorError.*` so the poller preserves existing outages.
3. Add a `StatusConnectorError` enum with associated values (HTTP
   status code, underlying error, path — same pattern as
   `ConnectorError`).

### Phase 2 — File manager per-vendor outage replacement

1. Add `update(with entries: [VendorUsageEntry], outagesByVendor: [Vendor: [Outage]]) async` on `UsagesFileManager`.
2. Inside the existing `flock`-guarded block, after the usage merge,
   apply the outage policy:
   - Iterate over `outagesByVendor` entries.
   - For each `(vendor, outages)`, remove all entries of that vendor
     from the existing outages, then append the new `outages`.
3. Rewrite the existing `update(with:)` as a thin wrapper calling the
   new method with an empty map (documents that connectors not passing
   an outage map preserve all outages — current behaviour).
4. Update the comment block at `merge(existing:incoming:)` to reflect
   that outages are now owned jointly by the app (for vendors with a
   status connector) and external producers (for others).

### Phase 3 — Poller integration

1. Extend `UsagePoller.init` to accept `statusConnectors: [any StatusConnector] = []`.
2. In `pollOnce`, after the usage `TaskGroup`, run a second
   `TaskGroup<(Vendor, Result<[Outage], Error>)>` over `statusConnectors`.
3. Build `outagesByVendor`: include only vendors whose fetch succeeded
   (success → `outages`, including `[]`). Vendors whose fetch failed
   (error) are omitted so their outages are preserved.
4. Log each failure at `.warning` with vendor + error description.
5. Call the new `fileManager.update(with:outagesByVendor:)` with the
   usage entries and the outage map.
6. The skip-if-fresh optimization for usages is unchanged; status
   fetches run on every tick (no cache) and on forced refresh.

### Phase 4 — Wiring and packaging

1. `AppDelegate.applicationDidFinishLaunching`: add
   `ClaudeStatusConnector()` to the poller's `statusConnectors`
   parameter.
2. Reuse `Loggers.claude` for the new connector (single Claude-scoped
   log file) unless the volume warrants a dedicated
   `Loggers.claudeStatus` — decide during implementation based on
   expected log verbosity.

### Phase 5 — Tests

- `ClaudeStatusConnectorTests.swift` (new):
  - Fixture with one `major` incident → one `Outage` with all fields
    mapped.
  - Fixture with `incidents: []` → `[]`.
  - Incident with `impact: "none"` → filtered out.
  - Incident with missing or malformed `shortlink` → `href: nil`, no
    throw.
  - HTTP 500 → throws `StatusConnectorError.unexpectedResponse`.
  - Network error (URLProtocol injects failure) → throws.
  - Malformed JSON → throws `StatusConnectorError.parseError` (or the
    connector's wrapped `DecodingError`).
- `UsagesFileManagerTests.swift` (extended):
  - `update(with: [], outagesByVendor: [.claude: [outage]])` on a file
    with prior Claude + Gemini outages → Claude replaced, Gemini
    preserved.
  - Same call with `[.claude: []]` → Claude removed, Gemini preserved.
  - Same call with `[:]` → all outages preserved (equivalent to the
    old `update(with:)`).
- `UsagePollerTests.swift` (extended):
  - Mock `StatusConnector` returning `[outage]` → file manager called
    with `[.claude: [outage]]`.
  - Mock throwing → file manager called with `[:]` for the vendor (or
    omits it from the map), preserving prior outages.
  - Forced refresh triggers status fetch exactly once per tick.

## Risk mitigation

- **File size / write amplification**: `update(with:outagesByVendor:)`
  still performs a single atomic write per tick even when both usages
  and outages change — unchanged pattern.
- **Race with external writer**: the flock covers the read-modify-write
  cycle for both usages and outages together. External writers that
  mutate outages between our read and write are overridden for the
  vendors we fetched successfully; others are preserved. This is the
  intended contract.
- **Statuspage schema drift**: DTO decodes only the four fields we
  need; unknown keys are ignored. Missing required fields throw a
  decoder error and the connector preserves existing outages.
- **Rate limiting**: Statuspage.io has no documented per-IP limit for
  public endpoints but we keep fetch frequency aligned with the user's
  `refreshInterval` (default 3 minutes) so steady-state load stays
  reasonable.

## Out of scope (reiterated)

- Status connectors for other vendors.
- A separate `StatusPoller` actor or a dedicated status-refresh cadence.
- Exposing a "last status refresh" timestamp in the UI.
- Notifications or menu-bar visual cues driven by status (the banner
  in the popover remains the only surface).

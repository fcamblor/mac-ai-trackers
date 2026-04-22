# Claude status connector

## Goal

Fetch Claude's incident data directly from the app so ongoing outages surface in the popover without relying on an external writer, and so the global refresh button updates outages alongside usage metrics.

## Dependencies

- [Vendor status monitor](vendor-status-monitor.md) — the `outages` schema, the `Outage` / `OutageSeverity` value objects, and the popover banner must exist first. This epic plugs a producer into the already-wired consumer path.

## Scope

- New `StatusConnector` protocol, symmetrical to `UsageConnector` but returning `[Outage]`. No OAuth, no Keychain — status pages are public.
- New `ClaudeStatusConnector` implementation reading Anthropic's public Statuspage.io endpoint for unresolved incidents. Payload mapping: incident name → `errorMessage`, impact → `OutageSeverity`, `created_at` → `since`, `shortlink` → `href`. Incidents with impact `none` are dropped.
- Poller integration: `UsagePoller` accepts a list of `StatusConnector`s and calls them in parallel to the existing `UsageConnector`s on each tick and on forced refresh.
- Per-vendor outage replacement in `UsagesFileManager`: a successful fetch for a vendor replaces that vendor's outages (empty list means "all clear"); a failed or absent fetch preserves them. Outages for other vendors are never touched.
- Cadence mutualized with the existing `refreshInterval` preference — no separate scheduling.
- The global refresh button path (`pollOnce(force: true)`) fetches both usages and outages.

**Out of scope**

- Status connectors for vendors other than Claude (addressed by their respective connector epics).
- Per-incident detail views, history, or notifications — the popover banner remains the only surface.
- Any change to the `Outage` / `OutageSeverity` schema or to the popover banner UI.
- A dedicated preference to disable status fetching.

## Acceptance criteria

- With an active Claude incident on Anthropic's status page, the popover shows the corresponding outage banner within one poll cycle, without any external writer running.
- When Anthropic's status page reports no unresolved incident, any previously written Claude outage in `usages.json` is cleared on the next successful fetch.
- A transient network or HTTP error during the status fetch leaves the existing outages for that vendor intact in `usages.json`; usages fetching for the same tick is not impacted.
- The global refresh button triggers an immediate outage fetch in addition to the usage fetch.
- Outages written for vendors other than Claude (by external producers or future connectors) survive a Claude status refresh unchanged.
- All new public methods have at least one test; network, parsing, and error paths are exercised with an injected `URLSession` / `URLProtocol` mock.
- SwiftLint reports zero errors and zero new warnings on the added files.

## Notes

- Statuspage.io endpoint used: `https://status.anthropic.com/api/v2/incidents/unresolved.json`. Schema is documented at <https://doers.statuspage.io/api/v2/>.
- Statuspage `impact` values map one-to-one onto existing `OutageSeverity` constants (`critical`, `major`, `minor`, `maintenance`). `none` is a non-outage and is filtered out.
- `errorMessage` uses the incident `name` (short, one-line) rather than the latest `incident_updates[0].body` (multi-paragraph) — the popover banner is compact and the `href` opens the full incident page.
- Status payloads are small (~2 KB) and change rarely, so no age-based skip is applied: every poll tick calls the status endpoint. Mutualizing the existing `refreshInterval` avoids a second preference and keeps the refresh button semantics simple.

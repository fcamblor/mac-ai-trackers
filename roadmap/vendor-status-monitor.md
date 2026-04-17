# Vendor status monitor

## Goal

Alert the user to ongoing incidents or degradations on AI vendor platforms directly within the popover, by reading outage data that an external process has already written into the shared JSON file.

## Dependencies

- [Menubar usage metrics display](menubar-usage-metrics.md)

## Scope

- **JSON schema evolution**: restructure `usages.json` so the top level is keyed by vendor. Each vendor section contains:
  - its accounts (nested under the vendor key),
  - an optional `outages` array holding active incident objects (title, severity, affected components, etc.) written by an upstream status-fetching process.
- **App-side display**: read the `outages` array for each vendor that has at least one configured account and surface any active incidents in the popover (exact placement to be decided during implementation — e.g. a banner per vendor card or a dedicated status section).
- Show enough incident detail (title, severity, affected components) for the user to understand the impact.
- The display refreshes automatically within the existing auto-refresh window (≤ 30 seconds) as the file is updated by the external process.

**Out of scope**

- The external process that fetches status pages and writes to `usages.json` (assumed to be a separate upstream tool, as with usage data today).
  - Reference vendor for the upstream fetcher: Claude status at `https://status.claude.com/`.
- Push notifications or OS-level alerts.
- Historical incident logs or uptime charts.
- Vendors for which no account is configured.

## Acceptance criteria

- When the `outages` array for a vendor is absent or empty, no incident indicator is shown for that vendor.
- When `outages` contains at least one entry for a vendor, a clear indicator appears in the popover and the user can read the incident title and affected components without leaving the app.
- A change in the `outages` data in `usages.json` is reflected in the popover within at most 30 seconds.
- The restructured JSON schema remains backward-compatible with the usage-metrics display (session, weekly, and pay-as-you-go data still renders correctly).

## Notes

- Vendor status pages typically implement the Atlassian Statuspage API — the upstream fetcher should prefer the JSON endpoint over HTML scraping.
- The JSON schema for the `outages` array must be defined and agreed on before implementation begins.

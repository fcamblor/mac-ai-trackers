# Roadmap

Ordered epics for the app. This file is the single source of truth for implementation order and feature status. Each item depends only on items listed above it.

Status values: `planned` | `in-progress` | `done`.

See `docs/ROADMAP.md` for the process and file conventions.

## Epics

1. `done` — [Menubar usage metrics display](menubar-usage-metrics.md) — show the active Claude account's session and weekly usage percentages plus reset delays in the macOS menubar.
2. `planned` — [Usage details popover](usage-details-popover.md) — open a polished popover on click with one card per account showing progress bars, reset dates, theoretical pace, and pay-as-you-go amounts.
3. `planned` — [Vendor status monitor](vendor-status-monitor.md) — surface active incidents from vendor status pages (Claude, and others as accounts are added) inside the app.
4. `planned` — [Consumption color indicators](consumption-color-indicators.md) — color menubar badge and progress bars by the ratio of actual to theoretical consumption across six severity tiers.
5. `planned` — [Settings window](settings-window.md) — open a native macOS settings window via a cog button in the popover for app-wide configuration.
6. `planned` — [Buy me a coffee](buy-me-a-coffee.md) — add a discreet donation button in the popover footer that opens the developer's donation page in the browser.

# Roadmap

Open epics for the app. This file is the single source of truth for the features still to implement and their inter-dependencies. Completed features are removed from this index and their files deleted.

Status values: `planned` | `in-progress`.

See `docs/ROADMAP.md` for the process and file conventions.

## Dependency graph

```mermaid
graph TD
    log-cleanup["Log cleanup"]
    vendor-status-monitor["Vendor status monitor"]
    settings-window["Settings window"]
    buy-me-a-coffee["Buy me a coffee"]
```

## Epics

1. `planned` — [Log cleanup](log-cleanup.md) — purge log entries older than 7 days at startup and once per day to keep log files bounded.
2. `planned` — [Vendor status monitor](vendor-status-monitor.md) — surface active incidents from vendor status pages (Claude, and others as accounts are added) inside the app.
3. `planned` — [Settings window](settings-window.md) — open a native macOS settings window via a cog button in the popover for app-wide configuration.
4. `planned` — [Buy me a coffee](buy-me-a-coffee.md) — add a discreet donation button in the popover footer that opens the developer's donation page in the browser.

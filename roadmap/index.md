# Roadmap

Open epics for the app. This file is the single source of truth for the features still to implement and their inter-dependencies. Completed features are removed from this index and their files deleted.

Status values: `planned` | `in-progress`.

See `docs/ROADMAP.md` for the process and file conventions.

## Dependency graph

```mermaid
graph TD
    log-cleanup["Log cleanup"]
    vendor-status-monitor["Vendor status monitor"]
    buy-me-a-coffee["Buy me a coffee"]
    codex-connector["Codex connector"]
    vendor-status-monitor --> codex-connector
    usage-history-snapshots["Usage history snapshots"]
```

## Epics

1. `in-progress` — [Log cleanup](log-cleanup.md) — purge log entries older than 7 days at startup and once per day to keep log files bounded.
2. `planned` — [Vendor status monitor](vendor-status-monitor.md) — surface active incidents from vendor status pages (Claude, and others as accounts are added) inside the app.
3. `planned` — [Buy me a coffee](buy-me-a-coffee.md) — add a discreet donation button in the popover footer that opens the developer's donation page in the browser.
4. `planned` — [Codex connector](codex-connector.md) — add OpenAI Codex CLI as a second tracked vendor alongside Claude.
5. `planned` — [Usage history snapshots](usage-history-snapshots.md) — periodically record metric values to a JSONL file for future consumption graph views.

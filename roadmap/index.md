# Roadmap

Open epics for the app. This file is the single source of truth for the features still to implement and their inter-dependencies. Completed features are removed from this index and their files deleted.

Status values: `planned` | `in-progress`.

See `docs/ROADMAP.md` for the process and file conventions.

## Dependency graph

```mermaid
graph TD
    log-cleanup["Log cleanup"]
    vendor-status-monitor["Vendor status monitor"]
    claude-status-connector["Claude status connector"]
    buy-me-a-coffee["Buy me a coffee"]
    codex-connector["Codex connector"]
    vendor-status-monitor --> codex-connector
    vendor-status-monitor --> claude-status-connector
    usage-history-snapshots["Usage history snapshots"]
```

## Epics

1`planned` — [Claude status connector](claude-status-connector.md) — fetch Claude incident data in-app so outages refresh without an external writer and share the global refresh button.
2`planned` — [Buy me a coffee](buy-me-a-coffee.md) — add a discreet donation button in the popover footer that opens the developer's donation page in the browser.
3`planned` — [Codex connector](codex-connector.md) — add OpenAI Codex CLI as a second tracked vendor alongside Claude.
4`planned` — [Usage history snapshots](usage-history-snapshots.md) — periodically record metric values to a JSONL file for future consumption graph views.

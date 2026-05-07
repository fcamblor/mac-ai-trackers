# Roadmap

Open epics for the app. This file is the single source of truth for the features still to implement and their inter-dependencies. Completed features are removed from this index and their files deleted.

Status values: `planned` | `in-progress`.

See `docs/ROADMAP.md` for the process and file conventions.

## Dependency graph

```mermaid
graph TD
    new-assistant-onboarding-workflow["Assistant onboarding and evolution workflow"]
```

## Epics

1. `planned` — [Assistant onboarding and evolution workflow](new-assistant-onboarding-workflow.md) — formalize the LLM-guided implementation, PR review, nightly-build attachment, tester validation, and merge gate for shipping any vendor-scoped change (new assistants and evolutions of existing ones, including backward-incompatible refactors and urgent fixes).

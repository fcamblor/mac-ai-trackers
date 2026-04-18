# Roadmap process

Planned work lives under `roadmap/` at the repository root. Unlike files in `docs/`, roadmap entries intentionally describe future, transient state — they are exempt from the "write for longevity" clauses of `.claude/rules/markdown-authoring.md`.

## Layout

- `roadmap/index.md` — open epics with their status and a Mermaid dependency graph. Single source of truth for ordering, dependencies, and status.
- `roadmap/<slug>.md` — one file per epic. Slug is kebab-case, English, concise.

When a feature ships, **both its epic file and its index entry are deleted**. The index only ever lists features that remain to be implemented.

## Granularity

One file equals one epic: a user-visible capability large enough to warrant a named milestone, small enough to be described on a single page. Sub-tasks of an epic stay inside its file and do not get their own roadmap entry.

## Feature file template

Each epic file follows this exact structure (omit `Notes` when empty):

```markdown
# <Epic name>

## Goal

<One or two sentences: the user problem solved.>

## Dependencies

<Bulleted list of links to other roadmap files, or the single word `None.`.>

## Scope

<Bulleted list of what is included.>

**Out of scope**

<Bulleted list of explicit boundaries.>

## Acceptance criteria

<Bulleted list of verifiable conditions.>

## Notes

<Optional. Technical constraints or architectural intent.>
```

Status does NOT appear in feature files — it lives only in `index.md` to avoid drift.

## Index format

`roadmap/index.md` contains two sections:

### Dependency graph

A Mermaid `graph TD` block listing every open epic as a node and every inter-dependency as a directed edge. Node IDs match epic slugs; labels are the epic display names. Edges point from dependency to dependent (`A --> B` means B depends on A). Isolated nodes (no dependencies among open epics) appear without edges.

```markdown
## Dependency graph

\`\`\`mermaid
graph TD
    epic-a["Epic A"]
    epic-b["Epic B"]
    epic-a --> epic-b
\`\`\`
```

### Epics list

An ordered list in topological order (dependencies first). Each entry uses this line format:

```markdown
1. `<status>` — [<Epic name>](<slug>.md) — <one-line summary>
```

Status values: `planned` | `in-progress`. Reordering or renumbering the list is how the plan is revised. The list must stay contiguous and in strict topological order.

## Creating a new epic

Use the `roadmap-feature` skill: it gathers context, checks for duplicates, writes the feature file, inserts it at the right position in the Epics list, and adds its node (and edges) to the Mermaid dependency graph.

## Closing a shipped epic

When a feature's acceptance criteria are all verified:

1. Remove the epic's line from the `## Epics` list and renumber.
2. Remove the epic's node and any edges involving it from the Mermaid graph.
3. Delete `roadmap/<slug>.md`.
4. Delete `roadmap/<slug>.plan.md` if it exists.

The `implement-roadmap-feature` Archon workflow handles all four steps automatically in its `close-feature` phase.

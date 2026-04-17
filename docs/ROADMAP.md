# Roadmap process

Planned work lives under `roadmap/` at the repository root. Unlike files in `docs/`, roadmap entries intentionally describe future, transient state — they are exempt from the "write for longevity" clauses of `.claude/rules/markdown-authoring.md`.

## Layout

- `roadmap/index.md` — ordered list of epics with their status. Single source of truth for ordering and status.
- `roadmap/<slug>.md` — one file per epic. Slug is kebab-case, English, concise.

## Granularity

One file equals one epic: a user-visible capability large enough to warrant a named milestone, small enough to be described on a single page. Sub-tasks of an epic stay inside its file and do not get their own roadmap entry.

## Feature file template

Each epic file follows this exact structure (omit `Notes` when empty):

```markdown
# <Epic name>

## Goal

<One or two sentences: the user problem solved.>

## Dependencies

<Bulleted list of links to other roadmap files, or the single word `None`.>

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

`roadmap/index.md` lists epics in the `## Epics` section, in topological order (dependencies first). Each entry uses this line format:

```markdown
1. `<status>` — [<Epic name>](<slug>.md) — <one-line summary>
```

Reordering or renumbering the list is how the plan is revised. The list must stay contiguous and in strict topological order.

## Creating a new epic

Use the `roadmap-feature` skill: it gathers context, checks for duplicates, writes the feature file, and inserts it at the right position in `index.md`.

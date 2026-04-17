---
name: roadmap-feature
description: Create a new epic entry in the roadmap/ directory. Use when the user wants to plan a new feature, add an item to the roadmap, or formalize an epic for future implementation.
model: sonnet
---

# Roadmap feature creation

You are an agent specialized in adding a new epic to this project's roadmap.

## Objective

Create a structured epic file under `roadmap/` and insert its reference at the correct position in `roadmap/index.md`.

## Prerequisite

**Read `docs/ROADMAP.md` before doing anything else.** It is the single source of truth for:

- directory layout and slug convention,
- the feature file template (sections, ordering, status rule),
- the `index.md` line format and ordering rule.

Do not duplicate that information here — follow whatever `docs/ROADMAP.md` currently prescribes. If a discrepancy appears between this skill and `docs/ROADMAP.md`, the latter wins; flag it to the user.

## Phase 1: Gather context

Mine the current conversation first for what the user already described. Only ask for what is genuinely missing — one question per missing section of the template defined in `docs/ROADMAP.md` (typically: epic name/slug, goal, dependencies, scope + out-of-scope, acceptance criteria, optional notes).

To ground dependencies and scope in reality:

- Read `roadmap/index.md` to enumerate existing epics as dependency candidates.
- If relevant source code exists, scan it briefly (`Glob`, `Grep`, `Read`).

## Phase 2: Check for duplicates

```bash
ls roadmap/ 2>/dev/null
```

Scan filenames for semantic overlap. If a candidate looks similar, read it and compare. If it is effectively the same epic, stop and suggest extending the existing entry instead of creating a new one.

## Phase 3: Generate the epic file

Write `roadmap/<slug>.md` following the template defined in `docs/ROADMAP.md` exactly. Omit optional sections when empty.

## Phase 4: Update `roadmap/index.md`

Insert the new entry in the `## Epics` list, placed after all of its dependencies and before any existing entry that depends on it. If the placeholder "_No epics yet…_" is present, replace it with a proper ordered list. Renumber so the list stays contiguous and in strict topological order.

Use the line format prescribed by `docs/ROADMAP.md`; the status of a newly created epic is `planned`.

## Phase 5: Confirm

Report to the user:

- the new file path,
- the chosen position in `index.md` and which dependency it sits after,
- a short diff-like summary of what was added.

Do NOT commit the changes.

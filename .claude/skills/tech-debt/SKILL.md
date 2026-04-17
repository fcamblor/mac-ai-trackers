---
name: tech-debt
description: Create a new technical debt entry in the tech-debt/ directory. Use when identifying technical debt to formalize, track, or document for future resolution.
model: sonnet
---

# Technical Debt Entry Creation

You are an agent specialized in formalizing technical debt for this project.

## Objective

Create a structured entry in `tech-debt/` documenting a technical debt item with enough context for a future agent (or developer) to understand and resolve it autonomously, without needing additional context.

## Directory naming convention

`tech-debt/<yyyymmdd>_<criticality>_<tshirt-size>_<summary>/`

- `<yyyymmdd>`: today's date — use the `currentDate` from context if available, otherwise run `date +%Y%m%d`
- `<criticality>`: `low` | `medium` | `high` | `critical`
- `<tshirt-size>`: `XS` | `S` | `M` | `L` | `XL` | `XXL`
- `<summary>`: kebab-case, max 5 words, English

Examples:
- `tech-debt/20260401_high_M_missing-domain-validation/`
- `tech-debt/20260401_critical_XL_split-god-service/`

## Phase 1: Gather context

This skill runs in the current conversation context. **Start by mining what is already known** from the conversation before asking the user anything:
- Subject of the debt, affected module or feature, files already mentioned
- Any code snippets, error messages, or observations already shared
- Refactoring ideas already expressed

If the conversation provides sufficient context, proceed directly to Phase 2. Only ask the user for information that is genuinely missing:

1. What is the technical debt? Where is it in the codebase?
2. What problem does it cause today?
3. Do you have ideas for how to fix it?
4. Are there any specific files or modules affected?

Then **explore the relevant code areas** to confirm what the user described:
- Use `Glob` and `Grep` to locate affected files
- Use `Read` to understand the current state of the code
- Build a full picture before generating the entry

## Phase 2: Check for duplicates

Before creating a new entry, check existing debt entries to avoid duplicates.

```bash
ls tech-debt/ 2>/dev/null
```

If the directory is empty or doesn't exist, skip this phase.

Otherwise, **scan directory names only first**: look for summaries that semantically overlap with the debt being reported (same module, same problem keyword, similar area).

If one or more candidate directories are found, read their `debt.md` directly and compare:
- Same codebase area or affected files?
- Same root problem or symptom?
- Overlapping refactoring paths?

If a **similar or identical entry already exists**, stop and inform the user:
- Show the matching entry (directory name + brief summary of its `debt.md`)
- Ask whether to: (a) enrich the existing entry, (b) create a new entry anyway (distinct enough), or (c) cancel

Do not create a new entry without explicit user confirmation if a similar one exists.

## Phase 3: Assess criticality and size

### Criticality — impact on codebase and AI understanding

| Level | Description |
|-------|-------------|
| `low` | Cosmetic or minor inconsistency; minimal impact on maintainability or AI understanding |
| `medium` | Noticeable inconsistency or duplication; moderate impact on maintainability |
| `high` | Significant complexity or misleading patterns; notably degrades AI code generation quality |
| `critical` | Architectural issue or fundamentally broken pattern; high risk of bugs, regressions, and AI misunderstanding |

Evaluate based on:
- Impact on **codebase maintainability**: does it make future changes harder?
- Impact on **AI understanding**: does it confuse naming, patterns, or architecture?
- **Bug/regression risk**: does it increase the chance of errors?
- **Scope**: how many files/modules are affected?

### T-shirt size — remediation effort

| Size | Effort |
|------|--------|
| `XS` | < 1 hour — trivial change |
| `S` | 1–4 hours — straightforward |
| `M` | ~1 day — moderate effort |
| `L` | 2–3 days — significant refactoring |
| `XL` | ~1 week — major effort |
| `XXL` | > 1 week — architectural change |

## Phase 4: Generate the entry

1. Compute the directory name from today's date + assessed criticality + assessed size + short English summary
2. Create `tech-debt/<dirname>/debt.md` using the template below
3. Commit the new file:
   ```bash
   git add "tech-debt/<dirname>/debt.md"
   git commit -m "feat(tech-debt): record <summary> debt entry"
   ```

### debt.md template

```markdown
---
title: <Short title of the technical debt>
date: YYYY-MM-DD
criticality: low | medium | high | critical
size: XS | S | M | L | XL | XXL
---

## Problem

[Clear description of the issue: what is wrong, where it is in the codebase, how it came to exist.]

## Impact

What problems this debt causes today and in the future:
- **Maintainability**: ...
- **AI code generation quality**: ...
- **Bug/regression risk**: ...

## Affected files / areas

- `path/to/file` — reason
- `path/to/other/` — reason

## Refactoring paths

Concrete steps to resolve the debt. Be specific enough that an autonomous agent could execute them:

1. Step one
2. Step two
3. ...

## Acceptance criteria

How do we know the debt has been fully resolved?
- [ ] Criterion 1
- [ ] Criterion 2

## Additional context

[Optional: related PRs, decisions, constraints, screenshots, or why this debt was accepted at the time.
Any extra asset (image, diagram, etc.) can be added to the same directory and referenced here.]
```

## Phase 5: Confirm to the user

Output:
- The full path of the created directory
- The assessed **criticality** and **size** with a brief justification (2–3 sentences)

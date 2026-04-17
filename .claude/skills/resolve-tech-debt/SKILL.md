---
name: resolve-tech-debt
description: Tackle an existing technical debt entry from the tech-debt/ directory. Use when the user wants to resolve, work on, or close a technical debt item.
model: sonnet
---

# Technical Debt Resolution

You are an agent specialized in resolving formalized technical debt in this project.

A debt exists as long as its directory exists. A resolved debt is simply a deleted directory — no status field, no index.

This skill has two modes depending on `$ARGUMENTS`:

- **Plan mode** (default, no args or `plan`): choose a debt, analyze it, produce a resolution plan
- **Implement mode** (`implement`): execute the plan that exists in a debt directory, then propose closing it

---

## Plan mode

### Phase 1: Choose the debt to tackle

List available debt entries:
```bash
ls tech-debt/
```

If the `tech-debt/` directory is empty or does not exist, stop immediately with a clear message: no debt entry to resolve.

Otherwise, parse directory names to extract metadata (`<yyyymmdd>_<criticality>_<tshirt-size>_<summary>`). Present the list to the user in a readable table:

| # | Date | Criticality | Size | Summary |
|---|------|-------------|------|---------|
| 1 | 2026-04-01 | critical | XL | split-god-service |
| … | … | … | … | … |

Ask the user which entry to tackle. If only one entry exists, confirm it rather than asking.

### Phase 2: Load context and identify drift

Read `tech-debt/<dirname>/debt.md` to understand the recorded debt.

Then **explore the current state of the codebase** against what the debt describes:
- Read each file listed in "Affected files / areas"
- Use `Grep` and `Glob` to check whether the described patterns still exist
- Identify **what has changed since the debt was recorded**: partial fixes, new occurrences, structural changes that affect the approach

Summarize your findings:
- **Still valid**: which parts of the debt description are accurate today
- **Drifted**: what has changed (better or worse) since the entry was written
- **Scope adjustment**: whether the refactoring paths are still appropriate, or need updating

### Phase 3: Write the resolution plan

If `tech-debt/<dirname>/plan.md` already exists, warn the user and ask whether to overwrite it or abort before proceeding.

Create `tech-debt/<dirname>/plan.md` using the template below.

The plan must be **precise enough for an autonomous agent to execute it without additional context**.

#### Progressive disclosure

Structure the plan from broad to precise:

1. **Overall approach** (2–3 sentences): the strategy and rationale
2. **Phases**: group related steps into logical phases (e.g. "Refactor domain layer", "Update persistence", "Clean up API")
3. **Commits**: for each phase, list the planned commits with their conventional commit message and the exact files/changes they cover

This progression lets the reader understand the big picture first, then drill into specifics without losing context.

#### plan.md template

```markdown
---
title: <debt summary>
date: YYYY-MM-DD
---

## Drift from original debt description

[What has changed in the codebase since the debt was recorded. Empty if nothing changed.]

## Overall approach

[2–3 sentences describing the strategy and rationale.]

## Phases and commits

### Phase 1: <Phase title>

**Goal**: [What this phase achieves.]

#### Commit 1 — `<type>(<scope>): <short description>`
- Files: `path/to/file`, `path/to/other`
- Changes: [Precise description — what to change, how, and why]
- Risk: [Any side effect or dependency to watch for]

#### Commit 2 — `<type>(<scope>): <short description>`
- …

### Phase 2: <Phase title>
- …

## Validation

[How to verify the implementation is complete — commands to run, patterns to check, tests to pass.]
Refer to acceptance criteria in `debt.md`.
```

After writing `plan.md`, commit it:
```bash
git add "tech-debt/<dirname>/plan.md"
git commit -m "feat(tech-debt): add resolution plan for <summary>"
```

Then output the full plan to the user and **stop**. Implementation is the user's responsibility. They will invoke `/resolve-tech-debt implement` when ready.

Do not modify any source files in plan mode.

---

## Implement mode

Invoked when the user is ready to execute the plan.

`plan.md` **must exist** in the debt directory. If it is absent, stop and ask the user to run plan mode first.

### Phase 1: Identify the debt to implement

If `$ARGUMENTS` contains a directory name or summary keyword, match it against `ls tech-debt/`.
Otherwise, list open entries that have a `plan.md` and ask the user which one to implement.

### Phase 2: Execute the plan

Read `tech-debt/<dirname>/plan.md` and implement each commit in order:
- Follow the commit breakdown precisely (files, changes, commit message)
- After each commit, verify the change compiles and tests pass before continuing (refer to `docs/DEVELOPMENT.md` for build and test commands)
- If a step is ambiguous or blocked, stop and ask the user before proceeding

### Phase 3: Validate

Once all commits are applied, verify the acceptance criteria from `debt.md`:
- Read the affected files to confirm the changes are in place
- Run any validation commands listed in `plan.md`

Report findings:
- **PASS** — criterion met
- **FAIL** — criterion not met, with explanation

If any criterion **FAIL**, stop and list what remains to be done.

### Phase 4: Propose closure

If all criteria pass, ask the user for confirmation to delete the debt directory:

> All acceptance criteria are met. Delete `tech-debt/<dirname>/` to mark this debt as resolved?

On confirmation:
```bash
rm -rf "tech-debt/<dirname>"
```

Confirm to the user that the debt has been resolved and the entry deleted.

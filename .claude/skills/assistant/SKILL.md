---
name: assistant
description: Routes to the correct sub-skill of the assistant family based on the issue's type:* and phase:* labels. Use when the user mentions a vendor onboarding or evolution and is unsure which skill to run.
model: sonnet
---

# Assistant workflow router

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md` first; it defines the type ↔ phase ↔
skill map and the rules every sub-skill enforces. If this skill and the
spec disagree, the spec wins; flag it to the user.

## Argument

A GitHub issue number.

## What this skill does

Identify which sub-skill to invoke. Do **not** perform any of the
sub-skill's work yourself — just route.

## Phases

### Phase A — Read the issue

```sh
gh issue view <n> --json number,title,labels,body,state,url
```

Note the labels:

- `type:new-assistant` or `type:vendor-evolution` (issue type).
- `kind:enrichment` / `kind:breaking` / `kind:urgent-fix` (only for
  vendor-evolution).
- `phase:*` (the lifecycle position).

If the issue carries neither `type:new-assistant` nor
`type:vendor-evolution`, refuse — the issue is not in scope of this
workflow.

If the issue carries no `phase:*` label, refuse and tell the user that
the issue is malformed (the issue forms apply `phase:proposed`
automatically; a missing phase label means manual editing happened).

### Phase B — Map phase to sub-skill

| `phase:*` | Skill to run |
|---|---|
| `phase:proposed` | `assistant-triage` (optional helper for the maintainer's decision draft) |
| `phase:approved` | `assistant-implement` (contributor starts work) |
| `phase:implementing` | `assistant-implement` (contributor resumes work) |
| `phase:review` | `assistant-review` |
| `phase:testing` | `assistant-tester-followup` (each time a tester comments) |
| `phase:merge-ready` | `assistant-merge` |
| `phase:merged` | `assistant-release` (only after a tagged release ships the merge commit) |
| `phase:released` | (terminal — no skill operates) |

For doc re-verification on a vendor whose onboarding issue is closed,
the right skill is `assistant-reverify` and it takes a vendor slug, not
an issue number — flag the mismatch if the user asked for that.

### Phase C — Hand off

Tell the user the matching skill name. Do not invoke it. Stop.

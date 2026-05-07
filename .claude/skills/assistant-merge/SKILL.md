---
name: assistant-merge
description: Verify gates one last time and squash-merge an assistant PR (new-assistant or vendor-evolution). Use when the issue is at phase:merge-ready.
model: sonnet
---

# Assistant merge

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md`; it owns the threshold rules
(including the `kind:urgent-fix` escape hatch) and the phase
transitions. If this skill and the spec disagree, the spec wins.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope and phase

Refuse unless the issue is at `phase:merge-ready`. Read the issue's
`type:*` and (when present) `kind:*` labels — they drive the threshold.

### Phase B — Re-verify gates

Re-run the tester tally (same logic as `assistant-tester-followup`)
against the current state. Re-run the reviewer checklist. Refuse to
merge if any gate is not green.

Threshold rules:

- `type:vendor-evolution` + `kind:urgent-fix` → ≥ 1 confirmation is
  sufficient.
- All other cases → ≥ 2 distinct confirmations on the latest build
  SHA, with audited-clean attached logs.

The PR author is allowed to count as one of those confirmations when
they post a sign-off comment as a tester.

### Phase C — Squash-merge

Use the standard commit convention from `docs/GIT-CONVENTIONS.md`. For
`kind:breaking`, ensure the commit title carries the `!` Conventional
Commits breaking marker.

```sh
gh pr merge <pr> --squash --subject "<conventional title>" --body "<conventional body>"
```

### Phase D — Apply `phase:merged`

```sh
gh issue edit <n> --remove-label "phase:merge-ready" --add-label "phase:merged"
```

Comment on the issue summarizing the merge and stating that the issue
will stay open until the next tagged release. For `kind:urgent-fix`,
also note: "Issue will stay at `phase:released` for follow-up tester
confirmations after the release ships."

### Phase E — Hand off

Once a tagged release ships including the merged commit, the next skill
is `assistant-release`.

---
name: assistant-merge
description: Verify gates one last time and squash-merge an assistant PR (new-assistant or vendor-evolution). Use when the issue is at phase:merge-ready.
model: sonnet
---

# Assistant merge

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md`; it owns the threshold rules
(including the `kind:urgent-fix` escape hatch) and the phase
transitions. Read `.claude/rules/skill-handoff.md` for the shared
Phase-A self-check and PR pre-flight pattern. If this skill and the
spec disagree, the spec wins.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope, phase, and PR pre-flight

Apply the Phase-A self-check from `.claude/rules/skill-handoff.md`
(mutex auto-correction). Refuse unless the issue is at
`phase:merge-ready`. Read the issue's `type:*` and (when present)
`kind:*` labels — they drive the threshold.

Run the PR pre-flight (`gh pr view <pr> --json isDraft,mergeable`).
Refuse if `isDraft=true` (cannot merge a draft) or `mergeable` is not
`MERGEABLE` (resolve conflicts first).

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

### Phase C — Pre-merge artefacts (commit on the PR branch)

Before merging, push the user-facing updates onto the PR branch so they
ship in the same commit as the code. Branch on `type:*`:

#### `type:new-assistant`

Update every README touchpoint that enumerates supported vendors (see
`docs/ASSISTANT-ONBOARDING.md` §3.1.6 for the full list — at minimum
"Supported Assistants" and "Cache and Logs"; scan for any other
Claude/Codex enumeration the README has grown since). Also add a row
to `docs/vendors/index.md` if it exists.

Before staging, re-grep the README for the previously supported vendor
slugs to confirm no enumeration was missed:

```sh
grep -nE 'Claude Code|Codex|claude-usages|codex-usages' README.md
```

Inspect the output, fix any missed touchpoint, then show the diff to
the user and propose to commit & push:

```sh
git checkout <pr-branch>
git add README.md docs/vendors/index.md
git commit -m "docs(<slug>): announce <Display Name> in README and vendor index"
git push
```

#### `type:vendor-evolution`

- Non-breaking → **no commit in this phase**. Skip straight to Phase D.
- `kind:breaking` → ensure the README's compatibility note (or the
  `Min app version` annotation in the vendor doc) is reflected
  wherever users decide which version to install. If an edit is
  needed, show the diff and propose:

  ```sh
  git checkout <pr-branch>
  git add <edited files>
  git commit -m "docs(<slug>): note <next-version>+ requirement"
  git push
  ```

  If no edit is needed (the compatibility note is already accurate),
  skip the commit and move to Phase D.

### Phase D — Draft release notes for the merge commit body

Draft the release-notes text now. It becomes the single source of
truth that the maintainer (or a release-engineering workflow) will
aggregate into the GitHub release notes when cutting the next tag.
Required content per type/kind, see `docs/ASSISTANT-ONBOARDING.md`
§3.1.6:

- All types — credit testers by handle (pull from the latest
  `assistant-tester-tally:sticky` comment).
- `kind:breaking` — prefix with
  `BREAKING: <vendor> connector requires <next-version>+` and explain
  what users on older versions will see (typically: `lastError`
  replacing live metrics).
- `kind:urgent-fix` — affected subset, since when, what the fix does.

Show the draft to the user for sign-off before Phase E.

### Phase E — Squash-merge

Use the standard commit convention from `docs/GIT-CONVENTIONS.md`. For
`kind:breaking`, ensure the commit title carries the `!` Conventional
Commits breaking marker. Embed the release-notes draft from Phase D as
the **body** of the squash-merge commit:

```sh
gh pr merge <pr> --squash \
  --subject "<conventional title>" \
  --body "<release-notes draft from Phase D>"
```

### Phase F — Apply `phase:merged`

```sh
gh issue edit <n> --remove-label "phase:merge-ready" --add-label "phase:merged"
```

Comment on the issue summarizing the merge and stating that the issue
will stay open until the next tagged release. For `kind:urgent-fix`,
also note: "Issue will stay at `phase:released` for follow-up tester
confirmations after the release ships."

### Phase G — Hand off

This is the terminal phase for the assistant skill family. The issue
stays open at `phase:merged` until a tagged release ships including the
merge commit; at that point the maintainer (or a release-engineering
workflow) transitions to `phase:released` and closes the issue.

The squash-merge commit body authored in Phase D is the single source
of truth for the release notes. It is the maintainer's responsibility
to aggregate merge commit bodies into the GitHub release notes when
they cut a tag — this skill does not edit `gh release` (it is a
destructive operation that would clobber concurrent vendor changes
shipped in the same release).

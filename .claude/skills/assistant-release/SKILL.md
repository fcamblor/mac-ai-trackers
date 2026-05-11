---
name: assistant-release
description: Officialize a merged assistant change once a tagged release ships — copy the squash-merge commit body into the GitHub release notes and close the issue. Use after a tagged release contains the merge commit.
model: sonnet
---

# Assistant release

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md`; it owns the per-type and per-kind
release-notes treatment. If this skill and the spec disagree, the spec
wins.

The README, `docs/vendors/index.md`, and the release-notes text were
already produced by `assistant-merge` and shipped in the squash-merge
commit. This skill does not regenerate them.

## Argument

A GitHub issue number, plus the released tag (e.g. `v0.4.0`).

## Phases

### Phase A — Verify scope and phase

Refuse unless the issue is at `phase:merged`. Read the issue's `type:*`
and (when present) `kind:*` labels. Confirm the released tag actually
contains the merge commit (`git tag --contains <commit>`).

### Phase B — Copy the merge commit body into the release notes

Locate the squash-merge commit on `main` (`gh pr view <pr> --json mergeCommit`).
Read its body (`git show -s --format=%b <sha>`) — that is the
release-notes draft authored during `assistant-merge` Phase D.

Show the user the current release notes and the proposed replacement,
then propose:

```sh
gh release view <tag> --json body,name
gh release edit <tag> --notes "<merge commit body>"
```

If the merge commit body is empty or visibly incomplete (missing tester
credits, missing `BREAKING:` prefix for `kind:breaking`, missing urgent
context for `kind:urgent-fix`), flag it as a process gap, draft the
missing pieces inline, and propose the amended notes — but do not
silently invent content.

### Phase C — Apply `phase:released` and close the issue

Propose the transition + close in one go (single Y/n confirmation):

```sh
gh issue edit <n> --remove-label "phase:merged" --add-label "phase:released"
gh issue comment <n> --body "Released in <tag>. Thanks to <testers>."
gh issue close <n>
```

For `kind:urgent-fix` where additional tester ✅ confirmations are
expected, leave the issue **open** at `phase:released` for a few days,
then close manually once enough confirmations have arrived.

### Phase D — Stop

This is the terminal state. No further skill operates on the issue.

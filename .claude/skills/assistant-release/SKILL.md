---
name: assistant-release
description: Officialize a merged assistant change by updating README (new-assistant only), docs/vendors/index, and crediting testers in release notes; close the issue. Use after a tagged release ships the work.
model: sonnet
---

# Assistant release

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md`; it owns the per-type and per-kind
release-notes treatment. If this skill and the spec disagree, the spec
wins.

## Argument

A GitHub issue number, plus the released tag (e.g. `v0.4.0`).

## Phases

### Phase A — Verify scope and phase

Refuse unless the issue is at `phase:merged`. Read the issue's `type:*`
and (when present) `kind:*` labels. Confirm the released tag actually
contains the merge commit (`git tag --contains <commit>`).

### Phase B — Update artefacts

Branch on `type:*`.

- `type:new-assistant` →
  - Append the new vendor to README's "Supported assistants" section.
  - Add a row to `docs/vendors/index.md` if it exists.
- `type:vendor-evolution` →
  - No README change (the vendor is already listed).
  - For `kind:breaking`, ensure the README's compatibility note (or the
    `Min app version` annotation in the vendor doc) is reflected
    wherever users decide which version to install.

### Phase C — Amend the GitHub release notes

```sh
gh release view <tag> --json body,name
gh release edit <tag> --notes "<amended notes>"
```

- All types → credit testers in the release notes by handle.
- `kind:breaking` → prefix the notes with
  `BREAKING: <vendor> connector requires <next-version>+` and explain
  what users on older versions will see (typically: `lastError`
  replacing live metrics until they update).
- `kind:urgent-fix` → call out the urgent context: which subset of
  users was affected, since when, what the fix does.

### Phase D — Apply `phase:released` and close the issue

```sh
gh issue edit <n> --remove-label "phase:merged" --add-label "phase:released"
gh issue comment <n> --body "Released in <tag>. Thanks to <testers>."
gh issue close <n>
```

For `kind:urgent-fix` where additional tester ✅ confirmations are
expected, leave the issue **open** at `phase:released` for a few days,
then close manually once enough confirmations have arrived.

### Phase E — Stop

This is the terminal state. No further skill operates on the issue.

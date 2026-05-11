---
name: assistant-review
description: Review an open assistant PR against the dual-track checklist (dated documentation first, then code), with per-issue-type addenda for new vendors vs evolution. Use when the issue is at phase:review.
model: opus
---

# Assistant review

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md` (lifecycle),
`docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md` (audit grid),
`docs/VENDOR-PLUGIN-CONTRACT.md` (technical contract), and
`.claude/rules/skill-handoff.md` (HITL execution pattern + PR
pre-flight checks) before starting. If this skill and any of those
disagree, the spec wins; flag it to the user.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope, locate the PR, and run the pre-flight

Refuse unless the issue is at `phase:review`. Apply the Phase-A
self-check from `.claude/rules/skill-handoff.md` (mutex auto-correction).

Find the linked PR via `Closes #<n>` in the PR body or the PR's
`Development` panel. If no PR is linked, refuse and ask the user to
point at the right PR.

Run the PR pre-flight from `.claude/rules/skill-handoff.md` §3:

```sh
gh pr view <pr> --json isDraft,mergeable,author,headRefOid
gh api user --jq '.login'
```

- `isDraft=true` → after review, the maintainer will need to
  `gh pr ready <pr>` for the assistant-build workflow to fire on the
  next push. Note this explicitly in the Phase F hand-off.
- `mergeable=CONFLICTING` → refuse and ask for a rebase first; the
  testers cannot install a DMG built from a conflicting branch.
- `author.login == <current user>` → use `gh pr review --comment` in
  Phase E (self-approval is forbidden by GitHub). Announce the
  substitution.

### Phase B — Documentation track FIRST

The dated documentation in `docs/vendors/<vendor>.md` must stand on its
own — read it before opening the diff. Walk every Documentation item of
the reviewer checklist. Bumped `Last verified`, per-section dates,
dated samples with plan tags, superseded samples annotated (never
deleted), Change log seeded (new-assistant) or appended (evolution).

### Phase C — Code track

Walk every Contract, Tests, and Sanitization item of the reviewer
checklist on the diff. Run the contract conformance test locally if the
maintainer has not already.

### Phase D — Per-type addenda

- `type:new-assistant` → vector PDF mark renders cleanly; `tintHex`
  readable; `VendorRegistry` registration in place; `AppDelegate`
  untouched.
- `type:vendor-evolution` → targeted refactor, no unrelated vendor
  touched; existing tests still pass; sanitization fixture updated. For
  `kind:breaking`, graceful-degradation path verified.

### Phase E — Post the review

Single PR review comment grouped by checklist section. Each line is
either a green check or a specific request for change. Approve only
if every item is green.

```sh
gh pr review <pr> --request-changes --body "<grouped findings>"
# or
gh pr review <pr> --approve --body "<all green summary>"
```

Do **not** auto-decide the verdict — approval vs change-request belongs
to the maintainer. But once they confirm the verdict, propose to flip
the phase label in the same turn rather than asking them to copy-paste:

- Approved → propose:
  ```sh
  gh issue edit <n> --remove-label "phase:review" --add-label "phase:testing"
  ```
- Changes requested → propose to roll back so the contributor can
  resume:
  ```sh
  gh issue edit <n> --remove-label "phase:review" --add-label "phase:implementing"
  ```

Ask for a single Y/n confirmation before running.

Reminder: when the Phase-A pre-flight flagged `author.login == current
user`, the command above must use `--comment` instead of `--approve`.

After the verdict-derived `gh issue edit` runs, surface follow-up notes
based on the pre-flight findings:

- PR still in draft → tell the maintainer to run `gh pr ready <pr>` so
  the assistant-build workflow fires on the next push.
- `phase:testing` is informational only — the build is gated on
  `ready_for_review`, not the label.

### Phase F — Hand off

Once `phase:testing` is set by the maintainer, the next skill is
`assistant-tester-followup`, invoked each time a tester comments.

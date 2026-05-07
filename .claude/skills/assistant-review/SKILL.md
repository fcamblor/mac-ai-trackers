---
name: assistant-review
description: Review an open assistant PR against the dual-track checklist (dated documentation first, then code), with per-issue-type addenda for new vendors vs evolution. Use when the issue is at phase:review.
model: opus
---

# Assistant review

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md` (lifecycle),
`docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md` (audit grid), and
`docs/VENDOR-PLUGIN-CONTRACT.md` (technical contract) before starting.
If this skill and any of those disagree, the spec wins; flag it to the
user.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope and locate the PR

Refuse unless the issue is at `phase:review`. Find the linked PR via
`Closes #<n>` in the PR body or the PR's `Development` panel. If no PR
is linked, refuse and ask the user to point at the right PR.

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

Do **not** apply `phase:testing` yourself — the maintainer transitions
the label after seeing the approved review. If the review requests
changes, suggest the maintainer roll back to `phase:implementing` so
the contributor can resume work.

### Phase F — Hand off

Once `phase:testing` is set by the maintainer, the next skill is
`assistant-tester-followup`, invoked each time a tester comments.

---
name: assistant-propose
description: Open the right `type:new-assistant` / `type:vendor-evolution` GitHub issue from a free-form intent. Use when the user says they want to support / fix / evolve a vendor and has not yet filed an issue.
model: sonnet
---

# Assistant propose

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md`; it owns the lifecycle, the issue
forms, and the label conventions. Read
`.claude/rules/skill-handoff.md` for the HITL execution pattern.

## Argument

A free-form intent ("I'd like to add support for X", "the Y connector
broke this week", etc.). No issue number — there is no issue yet.

## Phases

### Phase 0 — Bootstrap labels (delegate)

Run the bootstrap check from `assistant` Phase 0. If labels are
missing, propose to run `scripts/bootstrap-onboarding-labels.sh`
before proceeding — without the labels, `gh issue create --label …`
will fail.

### Phase A — Classify the intent

Decide between two issue forms based on the user's wording and on
`docs/vendors/<slug>.md` existence:

- "Add support for <new vendor>" + no `docs/vendors/<slug>.md` →
  `new-assistant-request.yml`.
- "The <existing vendor> connector is broken / drifted / needs X" +
  `docs/vendors/<slug>.md` exists → `vendor-evolution-request.yml`.

If the slug is ambiguous, ask the user once. Do not invent a slug from
a marketing name without checking `docs/vendors/`.

### Phase B — Pre-fill from existing context

For `type:vendor-evolution`, read `docs/vendors/<slug>.md` and the
related connector code to pre-populate the form's `Drift summary`,
`Evidence`, and `Affected since` fields when the user's intent
already contains that data. Do not invent evidence — leave a field
blank if the user has not provided it.

For `type:new-assistant`, mine the user's message for the slug,
display name, tint hex, credential sources, plan variants, API
references. Ask once for missing fields.

For `kind:urgent-fix`, surface the `Affected since` field explicitly —
its absence is the most common triage rejection reason.

### Phase C — Draft and confirm

Show the maintainer the complete pre-filled issue body (rendered as
Markdown), the title, and the labels that will be applied. Ask for a
single Y/n confirmation.

### Phase D — Create the issue

```sh
gh issue create \
  --title "<rendered title>" \
  --body "<rendered body>" \
  --label "<type:...>" \
  --label "phase:proposed"
```

(The issue forms apply `phase:proposed` automatically when filed from
the GitHub UI; this skill replicates the same labels because
`gh issue create` does not invoke the issue-form pipeline.)

### Phase E — Hand off

Print the new issue URL. Name `assistant-triage` as the next skill
once the maintainer is ready to triage.

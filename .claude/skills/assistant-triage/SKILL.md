---
name: assistant-triage
description: Help the maintainer triage a phase:proposed assistant issue (new-assistant or vendor-evolution) — duplicate check, scope sanity, kind:* label application, decision draft. Use when reviewing an incoming proposal.
model: sonnet
---

# Assistant triage

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md` first; it owns the lifecycle and the
phase ↔ skill map. Read `.claude/rules/skill-handoff.md` for the shared
HITL execution pattern (mutex auto-correction, single Y/n
confirmation). If this skill and the spec disagree, the spec wins.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope and phase

Read the issue. Refuse unless:

- `type:new-assistant` **or** `type:vendor-evolution` is set.
- `phase:proposed` is the current phase label.

If either condition fails, tell the user which skill should run instead.

### Phase B — Cross-check (same existence rule as `assistant-implement`)

The doc-existence rule MUST match the one enforced by
`assistant-implement` Phase C; otherwise the next skill stalls on a
discrepancy the triage already saw.

- Read `docs/vendors/` to detect duplicates of the requested vendor.
- For `type:new-assistant`: `docs/vendors/<slug>.md` MUST NOT exist.
  If it does, refuse and tell the maintainer to either (a) re-file as
  `type:vendor-evolution`, or (b) explicitly close-and-reopen with a
  decision recorded in the triage comment justifying why the existing
  doc is being reused. Do not invent a third path silently.
- For `type:vendor-evolution`: `docs/vendors/<slug>.md` MUST exist and
  the vendor MUST be registered in `VendorRegistry`. If not, refuse and
  point at the `type:new-assistant` form.
- Read `roadmap/index.md` for any conflicting open epic.

Record the existence-check outcome in the decision draft (Phase D) so
`assistant-implement` does not re-litigate it.

### Phase C — Apply `kind:*` label (vendor-evolution only)

Issue forms can only apply static labels from their frontmatter, so the
`kind:*` label corresponding to the dropdown selection is the triage
step's responsibility.

Read the issue body to identify the chosen kind:

- "kind:enrichment …" → `kind:enrichment`
- "kind:breaking …" → `kind:breaking`
- "kind:urgent-fix …" → `kind:urgent-fix`

For `kind:urgent-fix`, also check the `Affected since` field is filled.
A submission that picks `urgent-fix` without a timestamp is likely
mis-labelled — surface that to the maintainer in the decision draft.

```sh
gh issue edit <n> --add-label "kind:<chosen>"
```

For `type:new-assistant` issues, no `kind:*` label applies.

### Phase D — Draft a decision comment

Draft (do not post) a comment summarizing:

- Whether the request is in scope.
- Constraints: required credential sources, plan variants the testers
  must cover, branding asset acceptable sources.
- For `kind:urgent-fix`, an explicit confirmation that the vendor's API
  is currently broken in production (vs an announced future
  deprecation).
- For `kind:breaking`, the expected min app version bump.

Show the draft to the user. The decision (approve vs close) belongs to
the maintainer — do not pre-empt it. Once the maintainer confirms the
verdict, propose to execute the resulting GitHub action yourself rather
than asking them to copy-paste:

- Approve → propose to post the comment and flip the phase in one go:
  ```sh
  gh issue comment <n> --body "<approved decision>"
  gh issue edit <n> --remove-label "phase:proposed" --add-label "phase:approved"
  ```
- Close → propose to post the rejection comment and close:
  ```sh
  gh issue comment <n> --body "<rejection rationale>"
  gh issue close <n>
  ```

Ask for a single Y/n confirmation before running. Do not execute these
without explicit confirmation — the verdict itself remains a HITL
decision.

### Phase E — Hand off

Tell the user that, once `phase:approved` is set, the contributor
should run `assistant-implement` to start work.

---
name: assistant-triage
description: Help the maintainer triage a phase:proposed assistant issue (new-assistant or vendor-evolution) — duplicate check, scope sanity, kind:* label application, decision draft. Use when reviewing an incoming proposal.
model: sonnet
---

# Assistant triage

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md` first; it owns the lifecycle and the
phase ↔ skill map. If this skill and the spec disagree, the spec wins.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope and phase

Read the issue. Refuse unless:

- `type:new-assistant` **or** `type:vendor-evolution` is set.
- `phase:proposed` is the current phase label.

If either condition fails, tell the user which skill should run instead.

### Phase B — Cross-check

- Read `docs/vendors/` to detect duplicates of the requested vendor.
- For `type:new-assistant`: confirm `docs/vendors/<slug>.md` does **not**
  already exist; if it does, suggest the vendor-evolution form instead.
- For `type:vendor-evolution`: confirm `docs/vendors/<slug>.md` exists
  and that the vendor is registered in `VendorRegistry`; if not, suggest
  the new-assistant form instead.
- Read `roadmap/index.md` for any conflicting open epic.

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

Show the draft to the user. The **maintainer** posts the comment and
applies `phase:approved` (or closes the issue).

### Phase E — Hand off

Tell the user that, once `phase:approved` is set, the contributor
should run `assistant-implement` to start work.

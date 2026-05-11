---
name: assistant-tester-followup
description: Tally tester sign-off comments on a phase:testing issue, audit any attached connector logs for sanitization gaps, and draft follow-ups for incomplete confirmations. Use whenever a tester comments.
model: sonnet
---

# Assistant tester follow-up

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md`; it owns the sign-off template, the
counting rules (including cross-build validity — a sign-off on an
earlier SHA still counts as long as the attached log audits clean),
the threshold table, and the sanitization-audit discipline. Read
`.claude/rules/skill-handoff.md` for the shared Phase-A self-check and
the HITL execution pattern. If this skill and the spec disagree, the
spec wins.

## Re-run cadence

This skill is meant to run every time a tester comments on the issue.
To avoid manually re-invoking it after each comment, wrap it with
`/loop /assistant-tester-followup <n>` — the loop helper re-runs the
skill on its own cadence until the threshold is met. A pure CI-side
auto-tally is not viable because the sanitization audit of attached
logs requires Claude reading the file content.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope and phase

Apply the Phase-A self-check from `.claude/rules/skill-handoff.md`.
Refuse unless the issue is at `phase:testing`. Read the issue's
`type:*` and (when present) `kind:*` labels — they drive the
threshold.

### Phase B — Locate the latest build

Find the most recent `<!-- assistant-build:sticky -->` comment on the
issue. Extract the short SHA and the full SHA. This is the build the
tally references for newcomers; existing confirmations on prior builds
remain valid (cf. `docs/ASSISTANT-ONBOARDING.md` Counting rules).

### Phase C — Scan for sign-offs

Iterate through the issue's comments and pick the ones starting with the
`✅ tester-confirm` sentinel. For each, validate:

- the build SHA is present in the body (both forms — recorded for
  traceability, no longer required to match the latest sticky),
- required Verified boxes are ticked,
- a connector log file is attached (or the comment explicitly states
  verbose mode produced no output — that itself is a bug).

### Phase D — Audit attached logs

For each attached connector log:

- read it (or guide the user to fetch and read it),
- cross-check against the vendor doc's `Sanitized fields` section:
  every listed field MUST be redacted in the log,
- flag obvious secret patterns (long base64-ish strings, tokens,
  emails not declared as public in the vendor doc) as a sanitization
  gap.

A sanitization gap blocks the count and surfaces as a high-priority
finding for the maintainer — the connector code must be fixed and a
fresh DMG built before that confirmation can be re-counted. When
quoting a suspect line in the audit comment, replace the suspected
value with `<redacted>` so the issue thread itself never republishes a
leak.

### Phase E — Compute the threshold

| Issue labels | Threshold |
|---|---|
| `type:new-assistant` | ≥ 2 distinct confirmations |
| `type:vendor-evolution` + `kind:enrichment` | ≥ 2 distinct confirmations |
| `type:vendor-evolution` + `kind:breaking` | ≥ 2 distinct confirmations |
| `type:vendor-evolution` + `kind:urgent-fix` | ≥ 1 confirmation |

### Phase F — Sticky tally comment

Update or create the sticky tally comment on the issue (sentinel
`<!-- assistant-tester-tally:sticky -->`). Body shape:

```
<!-- assistant-tester-tally:sticky -->
Tester confirmations: N/<threshold> ✅

Latest build SHA: `<short>`

Valid confirmations:
- @<tester> — Plan: <plan>, macOS: <version>, build: `<short>`
- ...

Incomplete (please respond):
- @<tester> — Missing: <field>
- ...

Sanitization gaps (block merge):
- @<tester>'s log: line <n> contains a suspected secret
  pattern (`<redacted>` in the value field).
- ...
```

### Phase G — Verdict

- If `N >= threshold` and **no** sanitization gap is open → propose to
  flip the phase label yourself, asking for a single Y/n confirmation:
  ```sh
  gh issue edit <n> --remove-label "phase:testing" --add-label "phase:merge-ready"
  ```
  Then name `assistant-merge` as the next skill.
- Otherwise → list what is missing and ask the maintainer to wait /
  unblock. Do **not** apply any phase label yourself.

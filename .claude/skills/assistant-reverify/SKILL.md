---
name: assistant-reverify
description: Re-verify a vendor's API behavior against its docs/vendors/<vendor>.md snapshot, bump dates, append a Change log entry, and either open a doc-only PR (no drift impact) or file a type:vendor-evolution issue (drift forces connector changes). Use when API drift is suspected.
model: opus
---

# Assistant re-verify

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md` (re-verify section) and the
existing `docs/vendors/<vendor>.md`. If this skill and the spec
disagree, the spec wins.

## Argument

A vendor slug. **Not** an issue number — re-verification is decoupled
from any closed onboarding issue and never transitions a phase label.

## Phases

### Phase A — Read the existing vendor doc

Note the `Last verified` date and the dated payload samples. Identify
the API endpoints the connector exercises today.

### Phase B — Live capture

Capture fresh payloads (or guide the user to). Sanitize per the vendor
doc's `Sanitized fields` list before saving. Date the captures with
today's date.

### Phase C — Diff

Compare the fresh samples against the existing dated samples.
Categorize:

- **No drift** — fields, types, semantics unchanged.
- **Drift, no connector impact** — additive fields the connector
  ignores; cosmetic renames in fields the connector does not read.
- **Drift forcing connector changes** — fields the connector reads
  changed type, name, or semantics; endpoints moved; reset semantics
  changed.

### Phase D — Update the doc

Bump `Last verified` to today. Append the fresh dated samples. Mark
older samples `superseded by <today>` — never delete (the historical
trail is the value). Append a Change log entry describing what was
checked, what was unchanged, and what drifted.

### Phase E — Decide the follow-up path

- **No drift** or **drift with no connector impact** → open a small
  doc-only PR with the refreshed dates / samples / changelog. Stop
  here. No issue is required — nothing about the connector changes,
  so the testers / DMG / sanitization-audit gate adds no value.
- **Drift forcing connector changes** → DO NOT write connector code
  from this skill. DO NOT open a code PR directly. Instead, file (or
  instruct the maintainer to file) a `type:vendor-evolution` issue
  via `vendor-evolution-request.yml`, pre-filled with:
  - the drift summary,
  - the captured dated samples,
  - the proposed `kind:*` (`enrichment` / `breaking` /
    `urgent-fix` if the connector is currently broken in the field).

  The doc PR from phase D can either be merged independently first or
  rolled into the implementation PR opened later by
  `assistant-implement` — the maintainer decides.

  From there, the workflow takes over so the connector change goes
  through the testers / DMG / sanitization-audit gate like any other
  vendor evolution.

Never bundle re-verification with an old, already-closed onboarding PR.

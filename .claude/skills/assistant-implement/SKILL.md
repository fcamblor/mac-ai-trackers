---
name: assistant-implement
description: Scaffold (new-assistant) or refactor (vendor-evolution), document, test, and open a draft PR. Use when the issue is at phase:approved or phase:implementing and the contributor is starting or resuming work.
model: opus
---

# Assistant implement

## Prerequisite

Read `docs/ASSISTANT-ONBOARDING.md` (lifecycle) and
`docs/VENDOR-PLUGIN-CONTRACT.md` (technical contract). The Swift quality
docs listed in `CLAUDE.md` (`SWIFT-CONCURRENCY.md`,
`SWIFT-ERROR-HANDLING.md`, `SWIFT-IO-ROBUSTNESS.md`,
`SWIFT-TESTABILITY.md`, `SWIFT-VALUE-OBJECTS.md`,
`SWIFT-MENUBAR.md`) are mandatory before writing any Swift.

If this skill and the spec or the contract disagree, the spec/contract
win; flag it to the user.

## Argument

A GitHub issue number.

## Phases

### Phase A — Verify scope and phase

Read the issue. Refuse unless:

- `type:new-assistant` **or** `type:vendor-evolution` is set.
- Current phase is `phase:approved` **or** `phase:implementing`.

Read both `type:*` and (if present) `kind:*` labels — every later phase
branches on them.

### Phase B — Mine structured fields

Pull every fact from the issue body the contract needs. Ask the user
**only** for missing data.

- `type:new-assistant`: vendor slug, display name, tint hex, credential
  sources, plan variants, API references, branding asset.
- `type:vendor-evolution`: target vendor slug, kind, drift summary,
  evidence, app-version-impact (for `kind:breaking`), affected-since
  (for `kind:urgent-fix`).

### Phase C — Existence check

- `type:new-assistant` → `docs/vendors/<slug>.md` MUST NOT exist; refuse
  otherwise (point at the vendor-evolution form).
- `type:vendor-evolution` → `docs/vendors/<slug>.md` MUST exist and the
  vendor MUST be registered in `VendorRegistry`; refuse otherwise (point
  at the new-assistant form).

### Phase D — Vendor doc (research / re-research)

Branch on issue type. The user must approve the doc draft before
phase E.

- `type:new-assistant` → write `docs/vendors/<slug>.md` from
  `docs/vendors/_TEMPLATE.md` with `Last verified: <today>`, per-section
  dates, sources with retrieval dates, Change log seeded with
  "initial capture".
- `type:vendor-evolution` → bump the existing doc's `Last verified` to
  `<today>`; capture fresh dated payload samples; mark older samples
  `superseded by <today>` (do **not** delete them); update the
  Sanitized fields list if new payload fields appeared; append a Change
  log entry describing what drifted in the API and what changes in the
  connector. For `kind:breaking`, also annotate
  `Min app version: <next-version>` in the doc.

### Phase E — Code work

Branch on issue type.

- `type:new-assistant` → scaffold inline (Write/Edit), no shell script:
  connector, credential locator, status connector (if applicable),
  active-account monitor (if applicable), branding (with vector PDF
  mark `<slug>-mark.pdf`), `VendorRegistry` entry, test fixtures.
- `type:vendor-evolution` → locate the existing files for `<slug>` and
  apply the targeted refactor; do not touch unrelated vendors. For
  `kind:breaking`, prefer keeping a graceful-degradation path in the
  connector (e.g. return a `lastError` describing
  "incompatible API version" rather than crashing) so old app versions
  in the field stop logging useful metrics but do not crash.

### Phase F — Implement against the contract

After each plugin point, run targeted XCTest. Forbidden:

- `MetricKind.unknown` in connector output (contract test enforces).
- `try?` on correctness-affecting operations.
- `SecItem*` writes in the credential locator (read-only).
- Payload-bearing logger calls outside `LoggingProxy`.

### Phase G — Tests

- `type:new-assistant`: credential cascade (env / keychain / file each
  individually + cascade), payload happy path, every documented plan
  variant, HTTP error codes seen in the wild, metric calculation, date
  normalization, sanitization leakage.
- `type:vendor-evolution`: existing test suite still passes; new tests
  cover the new payload shape; sanitization leakage fixture updated for
  any new field; for `kind:breaking`, an explicit test verifies the
  graceful-degradation behavior on the legacy payload shape.

### Phase H — Open the draft PR

Use the assistant-change PR template. The body MUST start with
`Closes #<issue>`. Title convention:

- `type:new-assistant` → `feat(<slug>): support <Display Name> usage tracking`
- `type:vendor-evolution` → `feat(<slug>): <one-line drift summary>`
- `kind:breaking` → use `feat(<slug>)!:` and prepend `BREAKING:` to the
  body summary.

```sh
gh pr create --draft --template assistant-change.md \
  --title "<title>" --body "Closes #<n>

<body>"
```

Do **not** transition any phase label.

### Phase I — Hand off

Tell the maintainer to flip the issue to `phase:review` once the PR is
out of draft. Name `assistant-review` as the next skill.

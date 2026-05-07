# Reviewer checklist — assistant change

Audit grid for any PR linked to a `type:new-assistant` or
`type:vendor-evolution` issue. Read `docs/ASSISTANT-ONBOARDING.md` first;
it defines the lifecycle the checklist serves.

The PR template references this file. The `assistant-review` skill walks
this list section by section and posts its findings as a single grouped
review comment. Documentation is read **before** the diff — the vendor doc
must stand on its own.

If this checklist disagrees with `docs/ASSISTANT-ONBOARDING.md` or
`docs/VENDOR-PLUGIN-CONTRACT.md`, the spec wins; flag the discrepancy.

## Issue linkage

- [ ] PR body starts with `Closes #<issue>` and links an issue carrying
      `type:new-assistant` or `type:vendor-evolution`.
- [ ] Issue is currently at `phase:review`.
- [ ] (vendor-evolution only) `kind:*` label is present and matches the
      change.

## Contract

- [ ] Bundle registered in `VendorRegistry`; `AppDelegate` untouched.
- [ ] Credential locator implements `CredentialLocator`, read-only — no
      `SecItem*` writes, no writes to vendor config files.
- [ ] No `MetricKind.unknown` in connector output (contract test passes).
- [ ] `resetAt` values are strict ISO 8601 datetimes (DEBUG assertion
      holds).
- [ ] Active-account monitor implements `ActiveAccountMonitoring.start/stop`
      idempotently when a monitor is provided.

## Documentation (dated snapshot)

- [ ] `docs/vendors/<vendor>.md` carries `Last verified: YYYY-MM-DD` and
      per-section verification dates **bumped in this PR**.
- [ ] Sample payloads tagged with capture date and plan; superseded
      samples kept with annotation, never deleted.
- [ ] External source links carry retrieval dates.
- [ ] (new-assistant) Change log seeded with the initial-capture entry.
- [ ] (vendor-evolution) Change log entry added describing the drift,
      what changed in the connector, and any `kind:breaking` implications.
- [ ] (vendor-evolution + `kind:breaking`) `Min app version: <next-version>`
      annotation present in the doc.
- [ ] A reader unfamiliar with the codebase could reproduce the connector
      from this doc alone.

## Tests

- [ ] Credential cascade covered (env / keychain / file each individually
      + cascade).
- [ ] Each documented plan variant has a representative response fixture.
- [ ] HTTP error codes seen in the wild are tested (4xx / 5xx).
- [ ] Date normalization tested (calendar date → UTC midnight when
      applicable).
- [ ] (vendor-evolution + `kind:breaking`) An explicit test verifies the
      graceful-degradation behavior on the legacy payload shape.

## Sanitization

- [ ] `PayloadSanitizing` implementation present for the connector.
- [ ] `docs/vendors/<vendor>.md` `Sanitized fields` section is exhaustive
      vs the observed payload (every field captured in the dated samples
      is either safe to log or listed as redacted).
- [ ] Leakage test fixture (`Tests/Fixtures/<vendor>-full-payload.json`)
      seeded with realistic-looking secrets; the test asserts none survive
      sanitization.
- [ ] No connector log call passes a raw payload — every payload-bearing
      log entry routes through `LoggingProxy`.

## Build & validation (after `phase:testing`)

- [ ] DMG present in the issue's sticky build comment, filename matches
      `AI-Usages-Tracker-<vendor>-<sha8>.dmg`, SHA-256 listed, full commit
      SHA called out, vendor-debug slug shown.
- [ ] Tester threshold met on the latest build SHA — ≥ 2 distinct
      confirmations for `type:new-assistant` / `kind:enrichment` /
      `kind:breaking`; ≥ 1 for `kind:urgent-fix` (with follow-up
      confirmations expected post-release). The PR author may be one
      of the counted testers.
- [ ] Every counted confirmation lists the matching short SHA + full SHA
      in the sign-off body.
- [ ] Each counted confirmation has an attached connector log audited
      clean of secret leakage.
- [ ] Build-from-source path verified by the reviewer (optional spot
      check via `docs/CHECKOUT-AND-BUILD.md`).
- [ ] In-app feedback banner verified to appear in the tester DMG and to
      be absent from a stable build of the same commit (smoke test).

## Per-type addenda

### `type:new-assistant`

- [ ] Vector PDF icon (`<vendor>-mark.pdf`) renders cleanly in light + dark
      menu bars.
- [ ] `tintHex` matches vendor brand reasonably; readable on both bars.
- [ ] `VendorRegistry` registration in place; `AppDelegate` untouched.

### `type:vendor-evolution`

- [ ] Targeted refactor — only files for the affected vendor (and shared
      infrastructure if genuinely needed) are changed.
- [ ] Existing tests for the connector still pass; new tests cover the
      new payload shape.
- [ ] Sanitization leakage test fixture updated for any new field.
- [ ] (`kind:breaking`) Graceful-degradation path verified: an old app
      build hitting the new payload shape does not crash; it surfaces a
      `lastError` describing "incompatible API" and stops emitting metrics.

## Post-release follow-ups (handled by `assistant-release`)

- [ ] (new-assistant) README "Supported assistants" updated.
- [ ] (vendor-evolution) `docs/vendors/index.md` row reflects the new
      `Last verified` date if the index exists.
- [ ] GitHub release notes credit testers by handle.
- [ ] (`kind:breaking`) Release notes prefixed `BREAKING:` with min-version
      requirement called out.
- [ ] (`kind:urgent-fix`) Release notes call out the urgent context and
      affected-since timeline.

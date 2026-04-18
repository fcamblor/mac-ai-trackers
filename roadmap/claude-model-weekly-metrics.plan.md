---
title: Claude model-specific weekly metrics
date: 2026-04-18
---

# Implementation plan — Claude model-specific weekly metrics

## Overall approach

Extend `ClaudeCodeConnector.parseAPIResponse` to optionally extract `seven_day_sonnet` and `seven_day_opus` from the API JSON payload, then emit up to two additional `UsageMetric.timeWindow` entries alongside the existing session and weekly metrics. The parsing is gracefully optional: each per-model key is included only when present, non-null, and carrying a non-null `resets_at`. A debug log of the masked full payload is added on every HTTP 200 response. No UI changes are needed — downstream display components already handle arbitrary `timeWindow` metrics.

## Impacted areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift` — extend `ParsedUsage` struct and `parseAPIResponse` to extract optional per-model fields; add debug log on HTTP 200; emit additional metrics in `fetchUsages`
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/ClaudeCodeConnectorTests.swift` — new test cases covering all combinations of per-model key presence/absence plus debug log verification

## Phases and commits

### Phase 1 — Add debug logging of masked API payload

**Goal**: On every HTTP 200 response, log the full API payload at `.debug` level with sensitive fields masked, giving visibility into the raw API structure.

#### Commit 1 — `feat(connector): log masked API payload on HTTP 200`
- Files: `ClaudeCodeConnector.swift`
- Changes:
  - After receiving HTTP 200 and before calling `parseAPIResponse`, log the raw JSON at `.debug` level.
  - Mask sensitive fields (any field containing tokens or credentials) before logging. The payload structure from the usage endpoint does not contain secrets beyond what is already in memory, but apply a consistent masking pass to prevent accidental leaks if the API adds fields later.
- Risk: Logging must not break the data flow — use `try?` only for the log-formatting step (not for the main parse path). Ensure the log call does not retain the `Data` buffer beyond the log statement.

### Phase 2 — Extend parsing for per-model weekly metrics

**Goal**: Extract `seven_day_sonnet` and `seven_day_opus` optional fields from the API response and emit them as additional `UsageMetric.timeWindow` entries.

#### Commit 2 — `feat(connector): parse seven_day_sonnet and seven_day_opus from API response`
- Files: `ClaudeCodeConnector.swift`
- Changes:
  - Add optional fields to `ParsedUsage`: `sonnetWeeklyPercent: Int?`, `sonnetWeeklyResetAt: ISODate?`, `opusWeeklyPercent: Int?`, `opusWeeklyResetAt: ISODate?`.
  - In `parseAPIResponse`, after extracting the mandatory `five_hour` and `seven_day` blocks, optionally extract `seven_day_sonnet` and `seven_day_opus`. For each: check the key exists as `[String: Any]`, that `utilization` is a non-nil `Double`, and that `resets_at` is a non-nil `String`. Only populate the `ParsedUsage` optional fields when all three conditions hold; otherwise leave them `nil`.
  - In `fetchUsages`, after building the session and weekly metrics, conditionally append `UsageMetric.timeWindow(name: "Weekly Sonnet", resetAt: ..., windowDuration: weeklyWindowMinutes, usagePercent: ...)` and the equivalent for Opus, only when the parsed optional fields are non-nil.
  - Include per-model metrics in `lastKnownMetrics` so they are preserved across HTTP 429 responses.
- Risk: The mandatory `five_hour` / `seven_day` guard must remain unchanged — per-model keys are purely additive. If the API returns `seven_day_sonnet` with a null `resets_at`, that key must be silently skipped (no error thrown).

### Phase 3 — Tests

**Goal**: Full test coverage for all per-model key combinations.

#### Commit 3 — `test(connector): cover per-model weekly metrics parsing`
- Files: `ClaudeCodeConnectorTests.swift`
- Changes:
  - Add a helper function to build API response JSON that includes optional `seven_day_sonnet` and `seven_day_opus` blocks alongside the existing `five_hour` and `seven_day`.
  - New test cases:
    1. **Both per-model keys present** — response includes `seven_day_sonnet` and `seven_day_opus` with valid `utilization` and `resets_at`. Assert 4 metrics emitted: session, weekly, Weekly Sonnet, Weekly Opus. Verify names, percentages, window durations, and reset dates.
    2. **Only sonnet present** — `seven_day_opus` absent from JSON. Assert 3 metrics (session, weekly, Weekly Sonnet). No error raised.
    3. **Only opus present** — `seven_day_sonnet` absent from JSON. Assert 3 metrics (session, weekly, Weekly Opus). No error raised.
    4. **Both absent** — neither per-model key in JSON (matches current API shape). Assert 2 metrics (session, weekly) — existing behavior unchanged.
    5. **`resets_at` null on one key** — `seven_day_sonnet` present but `resets_at` is `null`. Assert that key is silently skipped; only session, weekly, and Weekly Opus emitted (if opus is valid).
    6. **Debug log emitted on HTTP 200** — verify that the logger receives a `.debug` call containing the payload after a successful response.
  - Ensure all existing tests still pass without modification (the mock API responses they use lack per-model keys, exercising the "both absent" path implicitly).
- Risk: Mock HTTP responses must exactly match the real API structure for the new keys. Use the same `JSONSerialization` approach as existing test helpers.

#### Commit 4 — `test(connector): cover per-model metrics preserved on HTTP 429`
- Files: `ClaudeCodeConnectorTests.swift`
- Changes:
  - New test: first fetch returns all 4 metrics (session, weekly, Weekly Sonnet, Weekly Opus). Second fetch returns HTTP 429. Assert that the error entry preserves all 4 metrics via `lastKnownMetrics`.
- Risk: None beyond the existing 429-preservation test pattern.

## Validation

- `swift build` compiles without warnings.
- `swift test` passes all existing tests plus the new ones.
- Verify acceptance criteria from `roadmap/claude-model-weekly-metrics.md`:
  - When `seven_day_sonnet` is present with valid `resets_at` → "Weekly Sonnet" metric emitted.
  - When `seven_day_opus` is present with valid `resets_at` → "Weekly Opus" metric emitted.
  - When either key is absent, null, or lacks `resets_at` → no metric emitted, no error.
  - Debug log written on every HTTP 200 with masked payload.
  - All existing tests still pass.

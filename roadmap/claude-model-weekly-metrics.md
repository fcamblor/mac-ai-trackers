# Claude model-specific weekly metrics

## Goal

Surface per-model weekly usage metrics (`seven_day_sonnet`, `seven_day_opus`) from the Claude API payload so users can see their Sonnet and Opus consumption windows independently alongside the existing session and weekly aggregates.

## Dependencies

- [Menubar usage metrics display](menubar-usage-metrics.md)

## Scope

- In `ClaudeCodeConnector`, after a successful HTTP 200 response, log the full (masked) API payload at `.debug` level so the raw structure is visible in logs.
- Parse `seven_day_sonnet` and `seven_day_opus` from the API response: each is included only when the key is present, non-null, and its `resets_at` field is also non-null.
- Emit two additional `UsageMetric.timeWindow` entries labelled `"Weekly Sonnet"` and `"Weekly Opus"` respectively, each with a 7-day window duration (10 080 minutes).
- Extend `parseAPIResponse` to return the optional per-model weekly fields without breaking existing session and aggregate-weekly parsing.

**Out of scope**

- Adding new UI components or changing the menubar string format (handled by downstream display epics).
- Supporting other per-model time windows beyond `seven_day_sonnet` and `seven_day_opus`.
- Logging unmasked / sensitive fields.

## Acceptance criteria

- When `seven_day_sonnet` is present, non-null, and has a non-null `resets_at`, a `"Weekly Sonnet"` metric appears in the emitted `VendorUsageEntry`.
- When `seven_day_opus` is present, non-null, and has a non-null `resets_at`, a `"Weekly Opus"` metric appears in the emitted `VendorUsageEntry`.
- When either key is absent, null, or lacks `resets_at`, no metric is emitted for it and no error is raised.
- A `.debug` log entry containing the masked full API payload is written on every successful HTTP 200 response.
- All existing tests pass; new unit tests cover: both keys present, one key absent, `resets_at` null on one key, both keys absent.

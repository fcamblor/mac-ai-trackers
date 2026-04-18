# Usage history snapshots

## Goal

Periodically record a snapshot of every metric value for every vendor account to a JSONL file, enabling future graph views that show consumption trends over time.

## Dependencies

None.

## Scope

- A `SnapshotRecorder` actor that appends one JSON line per metric per tick to a daily JSONL file.
- History files are partitioned by calendar day: `~/.cache/ai-usages-tracker/usage-history/{year}/{month}/{year}-{month}-{day}.jsonl` (e.g. `2025/04/2025-04-19.jsonl`). A new file is created automatically when the day rolls over.
- Each line encodes: ISO timestamp, vendor, account, metric name, metric kind, and the kind-specific value (`usagePercent` for `time-window`; `currentAmount` + `currency` for `pay-as-you-go`).
- A background timer fires every minute while the app is running.
- The timer reads the current state from `UsagesFileManager` (or a shared `UsageStore` if one is introduced).
- Snapshots are only written when at least one entry with metrics exists; ticks where no data is available are silently skipped.
- A line is appended only when at least one metric value has changed since the last written snapshot; ticks that would produce an identical record to the previous one are silently skipped (avoids bloating the file during idle periods).
- Each daily file is opened in append mode; existing history is never overwritten.
- `SnapshotRecorder` is injectable via protocol for testing.

**Out of scope**

- Any UI to display the history data (separate epic).
- Pruning or rotating the snapshot file (add to log-cleanup or a dedicated retention epic).
- Making the snapshot interval configurable from the UI (can be added once the Settings window epic ships).
- Exporting or sharing the history file.

## Acceptance criteria

- After one minute of uptime, today's daily file (`usage-history/{year}/{month}/{year}-{month}-{day}.jsonl`) exists and contains at least one line per active metric.
- Each line is valid JSON parseable as a `SnapshotEntry` struct (timestamp, vendor, account, metricName, kind, value fields).
- Restarting the app appends new lines rather than overwriting existing ones.
- When no data has been fetched yet, no empty or partial lines are written.
- `SnapshotRecorder` has unit tests covering: normal append, skip-when-empty, skip-when-unchanged, file-creation-on-first-tick, and day-rollover (new file created at midnight without losing the last line of the previous day).

## Notes

The snapshot cadence (1 min) is intentionally decoupled from the `UsagePoller` fetch cadence (3 min default). Multiple consecutive snapshot lines may therefore reflect the same underlying metric value between fetches — that is expected and useful for showing "still at X%" on a timeline.

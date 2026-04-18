# Log cleanup

## Goal

Prevent log files from growing indefinitely by automatically purging entries older than 7 days, keeping disk usage bounded without requiring manual intervention.

## Dependencies

- [Menubar usage metrics display](menubar-usage-metrics.md)

## Scope

- On app startup, scan all `FileLogger` log files and remove any line whose leading ISO 8601 timestamp is more than 7 days in the past.
- Schedule the same cleanup to run once per day while the app is running.
- Cleanup rewrites each log file atomically (write to a temp file, then replace).
- Both the startup pass and the daily timer share the same cleanup routine.

**Out of scope**

- Compressing or archiving old entries instead of deleting them.
- Configuring the retention window (hard-coded to 7 days matching the metrics time window).
- Cleaning log files that are not managed by `FileLogger` / `Loggers`.

## Acceptance criteria

- At app launch, any log line with a timestamp older than 7 days is absent from all log files after startup completes.
- A daily timer fires every 24 hours and repeats the same purge without restarting the app.
- Log files are rewritten atomically; a crash mid-cleanup leaves the previous file intact.
- Lines from the current 7-day window are never removed.
- Unit tests cover: all lines old (file cleared), all lines recent (file unchanged), mixed lines (only old lines removed), empty file (no crash), missing file (no crash).

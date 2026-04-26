# Usage history charts

Usage history charts are built from append-only JSONL snapshots under `~/.cache/ai-usages-tracker/usage-history/`. Each line is a `TickSnapshot` with every account and metric captured at that tick.

## Snapshot semantics

`SnapshotRecorder` writes a new line only when the account/metric payload changes. Daily files are partitioned by UTC date so the file name matches the timestamp date written in each line.

Time-window metrics whose `resetAt` is already in the past are recorded with `usagePercent: null`. This is intentional: `UsageHistoryReader` keeps those null points so `UsageHistoryChartView` can split line segments at reset or missing-data boundaries. Do not drop null time-window points in persistence or reader code unless the chart segmentation logic is changed at the same time.

Pay-as-you-go metrics use `currentAmount`; time-window metrics use `usagePercent`; unknown metric kinds are ignored when flattening history points.

## Reader behavior

`UsageHistoryReader` recursively reads `.jsonl` files, filters points to the selected window, ignores future points, counts malformed lines, and reports whether data exists before or after the current window. The view uses those flags to enable previous/next window navigation.

Decoded files are cached by path, modification date, and file size. If a test or feature mutates an existing history file, preserve the signature invalidation behavior so the reader reloads changed files.

Series summaries and the default all-available resolver include only series with at least one non-null point. This avoids legend entries for metrics that only appear through expiry markers.

## Chart configuration

Chart panels are stored in `UserDefaults` under `ai-tracker.chartConfigurations` and seeded once by `ChartConfigurationsSeeder`. The initialization flag is separate from the list so an intentionally empty chart list stays empty after the user deletes all charts.

A `ChartConfiguration` uses one of two mutually exclusive selection modes:

- `allAvailable`: resolve every history series that has at least one non-null point.
- `custom`: render the ordered `ChartSeriesConfig` list, preserving each series label, color, and line style.

Custom series can target either a specific account or the currently active account. The currently active account is resolved from the live `UsageStore` entries, not from historical data, so a custom chart tracks whichever account is active now.

## Rendering

`UsageHistoryChartView` renders one panel per configured chart. It removes null points from plotted `LineMark`s but keeps them in the per-series point stream to increment segment IDs, which breaks the line across null gaps.

Hover lookup is intentionally pre-grouped by series and uses a binary search to find nearest points. Avoid replacing it with a per-hover full scan; large history files can make hover updates frequent enough for that to become visible.

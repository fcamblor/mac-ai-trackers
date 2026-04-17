# Menubar usage metrics display

## Goal

Surface the active Claude account's usage metrics directly in the macOS menubar so the user can glance at consumption and remaining time before the next reset without opening a separate tool.

## Dependencies

None

## Scope

- Read the active Claude account's entry from `~/.cache/ai-usages-tracker/usages.json`.
- Compute and render, for that account, the session and weekly time windows as a compact menubar string (e.g. `S 48% 2h13m | W 7% 6d 6h 13m`), where each window shows the current usage percentage and the remaining delay until its next reset.
- Auto-refresh the menubar display so edits to `usages.json` propagate within 30 seconds.

**Out of scope**

- Multi-account switching or display of non-active accounts.
- Providers other than Claude.
- Historical views, charts, drill-downs, or any UI beyond the menubar string.
- Writing to or mutating `usages.json`.
- Configuring or ingesting Claude usage data into `usages.json` (assumed already populated by an upstream process).

## Acceptance criteria

- When `~/.cache/ai-usages-tracker/usages.json` exists and contains an active Claude account, the menubar shows its session and weekly percentages alongside the remaining delay to each window's reset.
- A manual edit of `~/.cache/ai-usages-tracker/usages.json` is reflected in the menubar within at most 30 seconds, with no user interaction.
- When the file is missing, empty, or malformed, the menubar degrades gracefully (no crash; a clear fallback state).

## Delivered

Feature shipped as scoped. The display refresh uses a hybrid file-watcher/polling
strategy rather than poll-only, and the countdown timer interval is configurable
(not hard-coded). All acceptance criteria from the original scope were met.

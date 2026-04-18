# Settings window

## Goal

Give users a dedicated window to configure the application, accessible via a settings icon in the popover.

## Dependencies

None.

## Scope

- Add a cog (⚙) icon button in the popover that opens a native macOS settings window.
- The settings window follows macOS HIG for preferences windows (tabbed or single-pane depending on the number of settings).

### Configurable settings

**Menu bar display items** — a multi-select group (at least one item must remain selected at all times):
- Show percentage
- Show time remaining until next reset
- Show weekly-only component
- Show 5-hour session component
- Show Sonnet weekly component

**Auto-refresh interval** — a discrete slider with five steps: 1 minute, 2 minutes, 3 minutes, 5 minutes, 10 minutes.

**Out of scope**

- In-popover inline settings (settings live only in the dedicated window).
- Cloud sync of preferences.
- Per-vendor or per-account configuration beyond what the settings window exposes.

## Acceptance criteria

- Clicking the cog icon in the popover opens the settings window; the popover closes.
- The settings window can be dismissed independently; it does not block the menubar item.
- Changes made in the settings window take effect without restarting the application.

## Notes

- The menu bar display group must enforce a minimum of one selected item (disabling the last checked option is not allowed).
- The discrete refresh-interval slider maps to fixed values [1, 2, 3, 5, 10] minutes; intermediate positions snap to the nearest defined step.

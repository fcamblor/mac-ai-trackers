# Settings window

## Goal

Give users a dedicated window to configure the application, accessible via a settings icon in the popover.

## Dependencies

- [Usage details popover](usage-details-popover.md)

## Scope

- Add a cog (⚙) icon button in the popover that opens a native macOS settings window.
- The settings window hosts app-wide configuration options (exact settings to be defined during implementation; candidates include refresh interval, account management, and launch-at-login).
- The window follows macOS HIG for preferences windows (tabbed or single-pane depending on the number of settings).

**Out of scope**

- In-popover inline settings (settings live only in the dedicated window).
- Cloud sync of preferences.
- Per-vendor or per-account configuration beyond what the settings window exposes.

## Acceptance criteria

- Clicking the cog icon in the popover opens the settings window; the popover closes.
- The settings window can be dismissed independently; it does not block the menubar item.
- Changes made in the settings window take effect without restarting the application.

## Notes

- Exact list of configurable settings to be agreed on before implementation begins.

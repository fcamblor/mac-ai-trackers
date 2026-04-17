# Consumption color indicators

## Goal

Make over- and under-consumption immediately legible by coloring metrics (menubar badge and progress bars) according to how actual consumption compares to the expected theoretical pace.

## Dependencies

- [Usage details popover](usage-details-popover.md)

## Scope

- Compute a consumption ratio: `actual_consumed / theoretical_consumed` for each time-window metric.
- Apply a color to the menubar badge and to each progress bar based on that ratio:

  | Ratio range      | Color  |
  |------------------|--------|
  | < 0.7            | Green  |
  | [0.7, 0.9)       | Blue   |
  | [0.9, 1.0)       | Yellow |
  | [1.0, 1.2)       | Orange |
  | [1.2, 1.6)       | Red    |
  | ≥ 1.6            | Black  |

- The menubar badge color reflects the color of the metric currently displayed in the menubar string (session and weekly by default); each displayed metric drives its own badge color independently.
- Which metrics are shown in the menubar — and therefore drive the badge color — is controlled by the app settings (see [Settings window](settings-window.md)).
- Pay-as-you-go metrics are not colored by this ratio (no theoretical pace concept).

**Out of scope**

- User-configurable thresholds or custom color palettes.
- Coloring pay-as-you-go amounts (no theoretical pace to compare against).
- Dark/light mode variants beyond what SwiftUI system colors provide automatically.

## Acceptance criteria

- Each time-window progress bar is filled with the color that matches its consumption ratio.
- The menubar badge color matches the color of the metric(s) configured to be displayed in the menubar string.
- Switching from one ratio bracket to another (e.g. by editing `usages.json`) updates the colors within the existing auto-refresh window (≤ 30 seconds).
- The color scheme is consistent between the menubar badge and the popover progress bars.

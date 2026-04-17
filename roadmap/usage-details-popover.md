# Usage details popover

## Goal

Give users a rich at-a-glance view of their AI consumption by opening a polished popover when they click the menubar item, showing one card per account with detailed usage breakdowns.

## Dependencies

- [Menubar usage metrics display](menubar-usage-metrics.md)

## Scope

- Open a popover anchored to the menubar item on click.
- Render one card per account; when multiple accounts exist for a given vendor, display the active account prominently (e.g. highlighted header or elevated visual weight).
- Inside each card, show:
  - **Time-window metrics** (e.g. session, weekly): a progress bar with label, consumed percentage, time remaining until the next reset, next-reset date, and a theoretical consumption indicator (expected consumed fraction given the window size and elapsed time).
  - **Pay-as-you-go metrics**: the amount consumed so far in the current billing period.
- UI must be polished and accessible: clear typography hierarchy, consistent spacing, smooth open/close animation.

**Out of scope**

- Editing or mutating any usage data.
- Account switching or authentication flows.
- Historical charts or trend views.
- Vendor configuration (handled by a future settings epic).

## Acceptance criteria

- Clicking the menubar item opens the popover; clicking elsewhere or pressing Escape closes it.
- Each vendor account appears as a distinct card; the active account is visually differentiated when multiple accounts share a vendor.
- Every time-window metric shows: label, progress bar filled to the consumed percentage, remaining delay, next-reset date, and a theoretical consumption marker on the progress bar.
- Every pay-as-you-go metric shows the consumed amount with currency symbol.
- The popover reflects the latest data from `usages.json` without requiring a restart.
- The layout remains readable with one account and with four or more accounts.

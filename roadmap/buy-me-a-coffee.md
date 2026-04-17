# Buy me a coffee

## Goal

Let users support the developer with a single click, surfaced unobtrusively inside the popover.

## Dependencies

- [Usage details popover](usage-details-popover.md)

## Scope

- Add a "Buy me a coffee" button (or equivalent small CTA) in the popover footer or a discreet corner.
- Clicking the button opens the developer's donation page in the default browser.
- The button is always visible but visually subordinate to the usage content.

**Out of scope**

- In-app payment processing.
- Hiding or suppressing the button after a donation.
- Analytics or tracking of click events.

## Acceptance criteria

- The button is present in the popover at all times.
- Clicking it opens the correct donation URL in the default browser.
- The button does not interfere with the layout of usage cards or other popover controls.

## Notes

- Donation URL to be provided before implementation.

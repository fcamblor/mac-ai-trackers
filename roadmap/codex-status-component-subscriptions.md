# Codex status component subscriptions

## Goal

Stop surfacing OpenAI status incidents that have nothing to do with Codex (Audio, Chat Completions, Sora, FedRAMP, …). The Codex outage banner should only fire when an incident actually affects a Codex-product component (Codex Web, App, CLI, VS Code extension, Codex API). The user controls which components count via a new preferences tab.

## Dependencies

None.

## Scope

- Discover Codex's child components dynamically from `https://status.openai.com/`. incident.io exposes no public unauthenticated JSON endpoint for components or groups, so we parse the Next.js RSC payload embedded in the page HTML and extract `{component_id, name, group_id}` triples. Filter to those whose `group_id` matches the "Codex" group root.
- Cache the discovered list locally; refresh on a 24h cadence (lazy: on app start if cache older than 24h, otherwise no work).
- Ship the initial implementation with an **empty** seed list, so the first user-visible refresh exercises the RSC parser end-to-end and any parsing regression is caught immediately (no silent fallback masking a broken parser). Once the parser is validated in production, a follow-up commit adds the seed list (the 5 components known today: Codex Web, App, Codex API, CLI, VS Code extension) for offline / fresh-install resilience.
- Cache both the `component_id` **and** the human-readable `name` for every discovered component. The id is the stable subscription key, but the preferences UI shows the name first so users get meaningful context (not a raw ULID).
- New preferences tab "Status" in `SettingsView`. Lists every cached Codex component with a per-component subscription toggle (default ON, including for components newly discovered on a future refresh). Shows the last successful refresh timestamp and a manual "Refresh now" button.
- Filter `CodexStatusConnector.fetchOutages()` so an incident is retained only if at least one of its `affected_components[].component_id` belongs to the set of currently-subscribed components. Incidents with zero subscribed components are dropped.
- Storage typology: data model and persistence are designed around a `StatusPlatform` concept (today only `incidentIO`) so that future vendors using other platforms (statuspage.io, …) can reuse the same registry + preferences UI shell without a refactor.
- Update `docs/vendors/codex.md` "Status page" section (replace the current "Component filter: none" claim with the actual filter description) and add a dated Change log entry.

**Out of scope**

- Applying the same filtering to Claude or Copilot. Their current status pages expose only vendor-specific incidents, so no filter is needed.
- Background timers / push notifications when component metadata changes.
- A diff UI surfacing which components were added or removed at the last refresh.
- Migrating preferences across versions if a `component_id` is renamed or replaced by OpenAI (we treat IDs as stable and accept that a rare replacement requires the user to re-toggle).
- Authenticated incident.io API integration.

## Acceptance criteria

- With the current Realtime/Audio outage live (`01KRG0AZKH41DV4D9SNJSXM33Q`, affects only the Audio component in the "APIs" group), no Codex banner appears in the popover.
- An incident affecting at least one subscribed Codex component surfaces a Codex banner with the existing severity + href rendering.
- Toggling a component OFF in the preferences hides incidents that only affect that component on the next outage refresh.
- The Status tab lists every component currently known for Codex, showing the `name` as the primary label and the `component_id` as secondary mono-small context.
- The initial release ships with an empty seed: on a fresh install with no successful refresh yet, the Status tab is empty and no Codex incidents are filtered in (parsing must succeed before subscriptions exist). A follow-up commit adds the seed and the acceptance criterion flips to "seed list applies on fresh install / offline".
- "Refresh now" updates the cached list synchronously and refreshes the displayed timestamp without restarting the app.
- If parsing the RSC payload fails (Next.js schema change), the connector logs a parse error and keeps using the last successful cache (which on the initial release means "no subscriptions" → no filtered-in incidents); tests assert the parser fails loud on a tampered fixture rather than silently returning an empty list.
- `docs/vendors/codex.md` documents the filter and lists the Codex group ID; reverification via `assistant-reverify` re-runs cleanly.

## Notes

- The Codex group root id observed today is `01KMKF9EBTCD8BN9PG8DJZXRSQ`. Its current children: `01JVCV8YSWZFRSM1G5CVP253SK` (Codex Web), `01KMKFAMWKQ81YWSE1Z18R6VHR` (App), `01KMP3KP5MGE23B80K1EK4S8PV` (Codex API), `01KMKFAMWKNQ84Z1766MV08ZDE` (CLI), `01KMP3KP5M8X0EBTVW6KN327EE` (VS Code extension).
- ULIDs assigned by incident.io are stable per-component; the realistic drift mode is "OpenAI adds a new child" (handled: default-subscribed) or "OpenAI removes a child" (handled: drops out of the cache on next refresh, its toggle becomes dead and can be GC'd).
- Cache file lives next to the existing usage cache; structure indexes by `(platform, status_page_host, group_root_id)` so adding a future vendor on the same platform does not collide.
- Preferences key per component is `component_id` (not name), because names like "App" or "CLI" are not unique across groups.
- The 24h cadence is intentionally loose — drift up to one day before a newly added Codex child is detected is acceptable; the manual refresh button is the escape hatch.

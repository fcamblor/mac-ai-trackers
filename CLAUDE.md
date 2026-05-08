# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Lazy-loaded context

Detailed guidelines live under `docs/` so this file stays small. Browse that directory and load the file whose topic matches your task — typical topics include development workflow (build, run, test commands), architecture (high-level structure and invariants), usage history charts (`docs/USAGE-HISTORY-CHARTS.md`), the roadmap process (how planned work is tracked under `roadmap/`), git conventions (`docs/GIT-CONVENTIONS.md`), the vendor plugin contract (`docs/VENDOR-PLUGIN-CONTRACT.md`), the assistant onboarding and evolution workflow (`docs/ASSISTANT-ONBOARDING.md`, with its reviewer checklist `docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md` and tester build-from-source guide `docs/CHECKOUT-AND-BUILD.md`), and per-vendor API research dated snapshots (`docs/vendors/<vendor>.md`). Do not load them preemptively.

## Swift code quality (mandatory)

When writing or modifying Swift code, you **must** load and follow all five Swift guideline docs before writing any code:

- `docs/SWIFT-CONCURRENCY.md` — cooperative thread pool, NSFormatter thread safety, actors, Process timeouts
- `docs/SWIFT-ERROR-HANDLING.md` — no silent `try?`, no success-after-catch, rich error types
- `docs/SWIFT-IO-ROBUSTNESS.md` — atomic writes, flock with timeout, O(n+m) merges
- `docs/SWIFT-TESTABILITY.md` — dependency injection, test coverage, force-unwrap, comments, magic numbers
- `docs/SWIFT-VALUE-OBJECTS.md` — value objects for domain fields, struct vs enum, ExpressibleByXxx, Codable
- `docs/SWIFT-MENUBAR.md` — menu bar UI: why we use `NSStatusItem` (not `MenuBarExtra`), non-template `NSImage`, menu bar appearance detection

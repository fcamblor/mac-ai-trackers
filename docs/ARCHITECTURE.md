# Architecture

An executable Swift Package produces a **menubar-only** macOS application: no Dock icon, no main window, and all interaction flows through a single menu bar item.

Invariants worth preserving when modifying the codebase:

- The app sets its activation policy to `.accessory` at startup. Removing this call makes macOS show a Dock icon and breaks the menubar-only contract.
- The UI is exposed through a SwiftUI `MenuBarExtra` scene. User-visible features belong inside that scene or in views it references — there is intentionally no main `WindowGroup`.

For authoritative details (Swift tools version, platform minimums, target layout), read the package manifest rather than mirroring them here.

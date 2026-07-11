<!-- Staging area for the next GitHub release body.
     Prepended to the auto-generated PR list by the release workflow.
     This file is automatically cleared by CI after each release tag is pushed. -->

## Bug Fixes

### 100% CPU usage while the usage popover is open

Fixed a render loop that caused the main thread to spin at 100% CPU whenever
the usage popover remained open for an extended period.

**Root cause:** The progress gauge bars (shown next to each usage percentage)
used `GeometryReader` to measure available width inside a lazy scroll view.
On macOS 26 (Tahoe), this combination caused SwiftUI's layout cache to
invalidate on every display frame (~60 Hz), which immediately requested
another render — creating an infinite loop that saturated the CPU.

**Fix:** Replaced `GeometryReader` + `ZStack` with `Canvas`, which receives
its size once from the layout system and draws everything in a single GPU pass
without creating child layout nodes. The layout cache now stays stable between
frames and no render loop is triggered.

No visual change to the gauge bars.

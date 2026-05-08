# Build it yourself

This guide walks a non-developer reader through cloning a pull request
and producing the same `.app` the maintainer attaches to an onboarding
issue. Use it when you want to validate a tester DMG before installing
it, or when you would rather not trust an ad-hoc-signed prebuilt.

The whole path takes ~5 minutes plus the time the build itself takes
(~2-5 minutes on a recent Mac).

## 1. Prerequisites

- **Xcode** — the version pinned by the package manifest. Install from
  the Mac App Store if you do not already have it. Open Xcode once after
  installing so it agrees to its license; on first build it may ask to
  download additional components.
- **macOS 15 or later**.
- **Git**. macOS ships a recent enough version; running `xcode-select
  --install` installs the developer command-line tools if needed.
- (Optional) **GitHub CLI** (`gh`) — convenient for checking out a PR by
  number. Install via `brew install gh` or skip and use the ZIP path
  below.

## 2. Get the source

### With `gh` (recommended)

```sh
gh repo clone fcamblor/ai-usages-tracker
cd ai-usages-tracker
gh pr checkout <pr-number>
```

`<pr-number>` is the number shown in the PR URL on GitHub.

### Without `gh`

On the PR's GitHub page, click **Code → Download ZIP** of the source
branch (the dropdown next to the green "Code" button on the PR's branch).
Unzip it and `cd` into the resulting directory.

## 3. Build

From the repository root:

```sh
./scripts/build-app-bundle.sh
```

The script compiles a release build, assembles `dist/AI Usages
Tracker.app`, and ad-hoc-signs it. Output lines starting with `→` mark
each step.

To reproduce the **tester-debug** mode locally (the one CI produces for
the build attached to a tester issue), set the same three environment
variables CI sets:

```sh
VENDOR_DEBUG=<vendor-slug> \
BUILD_COMMIT=$(git rev-parse HEAD) \
ONBOARDING_ISSUE_URL=https://github.com/fcamblor/ai-usages-tracker/issues/<n> \
  ./scripts/build-app-bundle.sh
```

`<vendor-slug>` is the lowercase identifier (e.g. `claude`, `codex`,
`copilot`) for the vendor under test. The three keys land in the produced
bundle's Info.plist; without them, the in-app tester feedback banner is
invisible by construction.

## 4. Run

```sh
open "dist/AI Usages Tracker.app"
```

If macOS refuses to launch the app because it is not from an identified
developer, **right-click** the `.app` in Finder and choose **Open**, then
confirm the dialog. This is the standard Gatekeeper bypass for ad-hoc
signed binaries — you only need to do it once.

## 5. (Optional) Compare against the maintainer's DMG

If you want to confirm the maintainer's prebuilt DMG matches what you
just built locally, compute its SHA-256:

```sh
shasum -a 256 ~/Downloads/AI-Usages-Tracker-<vendor>-<sha8>.dmg
```

The same value is published in the sticky build comment on the PR and on
the linked issue.

Note: Swift release builds are not strictly bit-for-bit reproducible
across machines and toolchain versions, so a SHA mismatch does not by
itself indicate tampering. The trust path here is "you read the source
and built it yourself"; SHA matching is a bonus when it works.

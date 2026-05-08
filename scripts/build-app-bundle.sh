#!/usr/bin/env bash
#
# Build a distributable .app bundle for the menubar app.
# Output: dist/AI Usages Tracker.app (ad-hoc signed, unsealed).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/AIUsagesTrackers"
DIST_DIR="$REPO_ROOT/dist"

APP_DISPLAY_NAME="AI Usages Tracker"
APP_BINARY_NAME="AIUsagesTrackers"
BUNDLE_ID="io.github.fcamblor.ai-usages-tracker"
BUNDLE_VERSION="${BUNDLE_VERSION:-0.1.0}"
MIN_MACOS_VERSION="14.0"

APP_BUNDLE="$DIST_DIR/$APP_DISPLAY_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
BUILD_CONFIG="release"
BUILD_DIR="$PACKAGE_DIR/.build/$BUILD_CONFIG"

echo "→ Building release binaries"
cd "$PACKAGE_DIR"
swift build -c "$BUILD_CONFIG" --product "$APP_BINARY_NAME"
swift build -c "$BUILD_CONFIG" --product IconExporter

# Resolve absolute build paths (swift emits a symlink in some configurations).
APP_BIN="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/$APP_BINARY_NAME"
ICON_EXPORTER_BIN="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/IconExporter"

echo "→ Assembling bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "→ Rendering .icns from AppIconView"
ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_TMP"
"$ICON_EXPORTER_BIN" "$ICONSET_TMP"
iconutil -c icns "$ICONSET_TMP" -o "$RESOURCES_DIR/AppIcon.icns"

echo "→ Copying executable"
cp "$APP_BIN" "$MACOS_DIR/$APP_BINARY_NAME"
chmod +x "$MACOS_DIR/$APP_BINARY_NAME"

# SwiftPM emits a resource bundle next to the binary for any target declaring
# `resources:`. The generated `Bundle.module` accessor looks for it relative to
# the executable URL, so it must sit alongside the binary in Contents/MacOS —
# not in Contents/Resources. Without this, the app fatal-errors on first access.
echo "→ Copying SwiftPM resource bundles"
BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
  bundle_name="$(basename "$bundle")"
  echo "  • $bundle_name"
  cp -R "$bundle" "$MACOS_DIR/"
  # SwiftPM emits a flat bundle (resources at the root, no Info.plist).
  # codesign rejects that as "bundle format unrecognized" — give it a minimal
  # Info.plist so the embedded bundle can be signed with the parent .app.
  bundle_basename="${bundle_name%.bundle}"
  cat > "$MACOS_DIR/$bundle_name/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID.resources.$bundle_basename</string>
  <key>CFBundleName</key>
  <string>$bundle_basename</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
</dict>
</plist>
PLIST
done
shopt -u nullglob

# Tester-debug mode (see docs/ASSISTANT-ONBOARDING.md §6.3): three env
# vars, all-or-nothing. The CI workflow assistant-build.yml sets the
# trio together; the release workflow MUST NOT pass any of them.
TESTER_DEBUG_KEYS=""
if [ -n "${VENDOR_DEBUG:-}" ] || [ -n "${BUILD_COMMIT:-}" ] || [ -n "${ONBOARDING_ISSUE_URL:-}" ]; then
  if [ -z "${VENDOR_DEBUG:-}" ] || [ -z "${BUILD_COMMIT:-}" ] || [ -z "${ONBOARDING_ISSUE_URL:-}" ]; then
    echo "✗ Tester-debug mode requires VENDOR_DEBUG, BUILD_COMMIT, and ONBOARDING_ISSUE_URL to be all set or all unset" >&2
    exit 1
  fi
  case "$ONBOARDING_ISSUE_URL" in
    https://github.com/*/issues/*) ;;
    *)
      echo "✗ ONBOARDING_ISSUE_URL must look like https://github.com/<owner>/<repo>/issues/<n>" >&2
      exit 1
      ;;
  esac
  TESTER_DEBUG_KEYS=$(cat <<KEYS
  <key>AITrackerVendorDebug</key>
  <string>$VENDOR_DEBUG</string>
  <key>AITrackerBuildCommit</key>
  <string>$BUILD_COMMIT</string>
  <key>AITrackerOnboardingIssueURL</key>
  <string>$ONBOARDING_ISSUE_URL</string>
KEYS
)
  echo "→ Tester-debug mode active (vendor=$VENDOR_DEBUG, commit=${BUILD_COMMIT:0:8})"
fi

echo "→ Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_BINARY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_MACOS_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>© $(date +%Y) Frédéric Camblor</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>AI Usages Tracker checks System Events for legacy login items so toggling "Launch at login" stays consistent and avoids registering duplicate entries.</string>
$TESTER_DEBUG_KEYS
</dict>
</plist>
PLIST

echo "→ Ad-hoc code-signing (required for Gatekeeper on unsigned binaries)"
codesign --force --deep --sign - "$APP_BUNDLE"

# Optional DMG packaging — used by the assistant-build CI workflow to
# produce a tester-friendly artefact named after the vendor + short SHA.
# Set DMG_OUTPUT to the desired path to opt in.
if [ -n "${DMG_OUTPUT:-}" ]; then
  echo "→ Packaging DMG: $DMG_OUTPUT"
  rm -f "$DMG_OUTPUT"
  hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$APP_BUNDLE" \
    -ov -format UDZO \
    "$DMG_OUTPUT" >/dev/null
  shasum -a 256 "$DMG_OUTPUT" > "$DMG_OUTPUT.sha256"
  echo "  $(cat "$DMG_OUTPUT.sha256")"
fi

echo
echo "✓ Bundle ready: $APP_BUNDLE"
echo "  Launch with: open \"$APP_BUNDLE\""

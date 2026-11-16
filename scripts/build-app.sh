#!/bin/bash
# Builds "build/Claude Multi Account.app" (manager + embedded ProfileAgent), signs and verifies it.
# Env: UNIVERSAL=1 (arm64+x86_64), CODESIGN_IDENTITY (default ad-hoc "-"), VERSION, BUILD_NUMBER,
#      SCRATCH_PATH (SwiftPM scratch dir, default .build).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Claude Multi Account"
BUNDLE_ID="com.apolloautomation.claudemultiaccount"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IDENTITY="${CODESIGN_IDENTITY:--}"
SCRATCH="${SCRATCH_PATH:-.build}"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

BUILD_ARGS=(-c release --scratch-path "$SCRATCH")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

log "swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}" --product ProfileAgent
swift build "${BUILD_ARGS[@]}" --product ClaudeMultiAccount
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

MANAGER_BIN="$BIN_DIR/ClaudeMultiAccount"
AGENT_BIN="$BIN_DIR/ProfileAgent"
[[ -x "$MANAGER_BIN" ]] || die "manager binary missing: $MANAGER_BIN"
[[ -x "$AGENT_BIN" ]] || die "agent binary missing: $AGENT_BIN"

log "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$MANAGER_BIN" "$APP/Contents/MacOS/ClaudeMultiAccount"
cp "$AGENT_BIN" "$APP/Contents/Resources/ProfileAgent"
chmod 755 "$APP/Contents/MacOS/ClaudeMultiAccount" "$APP/Contents/Resources/ProfileAgent"

# App icon: only if the manager supports --render-app-icon (checked via the binary's strings, so an
# unsupported build is never launched as a GUI app). Failure is non-fatal.
ICON_KEYS=""
ICON="$APP/Contents/Resources/AppIcon.icns"
if grep -aq -- "--render-app-icon" "$MANAGER_BIN"; then
  log "rendering app icon"
  "$MANAGER_BIN" --render-app-icon "$ICON" >/dev/null 2>&1 &
  ICON_PID=$!
  for _ in $(seq 1 60); do kill -0 "$ICON_PID" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$ICON_PID" 2>/dev/null; then kill "$ICON_PID" 2>/dev/null || true; fi
  wait "$ICON_PID" 2>/dev/null || true
  if [[ -s "$ICON" ]]; then
    ICON_KEYS="<key>CFBundleIconFile</key><string>AppIcon</string>"
  else
    rm -f "$ICON"; log "icon render failed; continuing without icon"
  fi
else
  log "manager has no --render-app-icon; skipping icon"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ClaudeMultiAccount</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  $ICON_KEYS
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Claude Multi Account sends links to the right Claude window, brings profiles to the front and pauses music while Claude listens.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Claude Multi Account creates Desktop shortcuts for your profiles when you ask it to.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Claude Link</string>
      <key>CFBundleURLSchemes</key><array><string>claude</string></array>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist invalid"
printf 'APPL????' > "$APP/Contents/PkgInfo"

log "signing (identity: $IDENTITY)"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then SIGN_ARGS+=(--timestamp=none); else SIGN_ARGS+=(--options runtime --timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/ProfileAgent"
codesign "${SIGN_ARGS[@]}" "$APP"

log "verifying"
codesign --verify --strict "$APP/Contents/Resources/ProfileAgent"
codesign --verify --strict --verbose=1 "$APP"
lipo -info "$APP/Contents/MacOS/ClaudeMultiAccount" || true

log "done: $APP"

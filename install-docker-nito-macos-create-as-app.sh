#!/usr/bin/env bash
#
# install-docker-nito-macos-create-as-app.sh — Build a double-clickable macOS
# app that runs the install-docker-nito-macos.sh installer in Terminal.
#
set -euo pipefail

APP_NAME="${APP_NAME:-nito}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/aktak/builds/main/install-docker-nito-macos.sh}"
BUNDLE_ID="${BUNDLE_ID:-sk.park.cito.install-nito}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This builder only runs on macOS." >&2
  exit 1
fi

# Prefer the system /Applications (what users mean by "Applications folder" and
# always Spotlight-indexed); fall back to ~/Applications if it isn't writable.
if [[ -z "${APP_BUNDLE:-}" ]]; then
  if [[ -w /Applications ]]; then
    APP_BUNDLE="/Applications/${APP_NAME}.app"
  else
    APP_BUNDLE="$HOME/Applications/${APP_NAME}.app"
    mkdir -p "$HOME/Applications"
  fi
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict>
</plist>
PLIST

cat > "$APP_BUNDLE/Contents/MacOS/launcher" <<LAUNCHER
#!/bin/bash
osascript \\
  -e 'tell application "Terminal" to activate' \\
  -e 'tell application "Terminal" to do script "bash <(curl -fsSL ${SCRIPT_URL})"'
LAUNCHER

chmod +x "$APP_BUNDLE/Contents/MacOS/launcher"

# Strip Gatekeeper quarantine so the bundle we just built locally launches cleanly.
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# Register with LaunchServices so Finder AND Spotlight see it immediately.
# (touch alone only bumps mtime; it does not register the bundle.)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" || true
fi
touch "$APP_BUNDLE"

echo "Created: $APP_BUNDLE"
echo "Open it from Finder (or: open \"$APP_BUNDLE\")."

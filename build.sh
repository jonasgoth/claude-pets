#!/bin/bash
# Builds build/Claude Pets.app from the Swift package. Add --run to launch it afterwards.
#   ./build.sh          just build
#   ./build.sh --run    build, then (re)launch the app
set -euo pipefail
cd "$(dirname "$0")"

# Set by CI from the git tag (tools/make-dmg.sh and .github/workflows/release.yml);
# otherwise this is the version a local build carries.
VERSION="${CLAUDE_PETS_VERSION:-0.6.0}"
APP="build/Claude Pets.app"

echo "Compiling Claude Pets…"
swift build -c release
BIN=".build/release/ClaudePets"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudePets"
# Animated Clawd pets (frame sheets baked by tools/render-pets.py).
mkdir -p "$APP/Contents/Resources/pets"
cp Assets/pets/*.png Assets/pets/manifest.json "$APP/Contents/Resources/pets/"
# The slice of the Hugeicons font the menu icons are drawn from.
mkdir -p "$APP/Contents/Resources/fonts"
cp Assets/fonts/*.ttf "$APP/Contents/Resources/fonts/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Pets</string>
  <key>CFBundleDisplayName</key><string>Claude Pets</string>
  <key>CFBundleIdentifier</key><string>app.claudepets.ClaudePets</string>
  <key>CFBundleExecutable</key><string>ClaudePets</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>MIT. Unofficial; not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

# Strip Finder metadata (codesign rejects it), then sign so macOS lets it run locally.
# An ad-hoc signature changes on every build, and macOS ties the Accessibility grant to
# the exact signature — so "Window checks" turns itself off after each rebuild even though
# System Settings still lists Claude Pets. Signing with a self-signed certificate instead keeps
# the grant. Make one in Keychain Access (Certificate Assistant > Create a Certificate,
# type "Code Signing") and name it Claude Pets Dev, or point CLAUDE_PETS_SIGN_IDENTITY at your own.
xattr -cr "$APP"
IDENTITY="${CLAUDE_PETS_SIGN_IDENTITY:-Claude Pets Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x ClaudePets 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "Launched. Look for the crab in your menu bar and along the bottom of the screen."
fi

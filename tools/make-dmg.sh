#!/bin/bash
# Builds the app and wraps it in a drag-to-Applications DMG: build/claude-pets-<version>.dmg
# The disk image opens as a window with the crab on the left, Applications on the
# right and an arrow in between (Assets/dmg/background.tiff, drawn by
# tools/make-dmg-background.py).
#
# The app is ad-hoc signed unless a "Developer ID Application" certificate is in your keychain.
# Ad-hoc builds run fine locally; other people must right-click > Open the first time.
# To ship without that warning you need an Apple Developer account, then:
#   1. codesign --force --options runtime --timestamp --sign "Developer ID Application: …" "build/Claude Pets.app"
#   2. xcrun notarytool submit build/claude-pets-<version>.dmg --keychain-profile <profile> --wait
#   3. xcrun stapler staple build/claude-pets-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh

VOL="Claude Pets"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "build/Claude Pets.app/Contents/Info.plist")"
OUT="build/claude-pets-${VERSION}.dmg"
STAGE="build/dmg-stage"
RW="build/dmg-rw.dmg"
# Icon centres in the window; keep in step with tools/make-dmg-background.py.
APP_X=170; APPS_X=490; ICON_Y=200
WIN_W=660; WIN_H=420

# Anything still mounted from a previous run would steal the volume name.
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true

rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
cp -R "build/Claude Pets.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Assets/dmg/background.tiff "$STAGE/.background/background.tiff"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 24 ))
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW \
               -size "${SIZE_MB}m" -ov "$RW" >/dev/null

DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOL"

# Lay the window out. Finder is what actually arranges a DMG window, and it is not
# available on a CI runner (no logged-in desktop), so there are two paths:
#   - a Mac with a desktop: drive Finder, then save the layout it produced back into
#     Assets/dmg/DS_Store so CI keeps getting the same window;
#   - CI, or a Mac that refuses to let us control Finder: drop that saved file in.
# A .DS_Store holds the icon positions, window size and background reference, so the
# replayed layout is identical to the hand-made one.
LAYOUT="Assets/dmg/DS_Store"
use_finder=true
[[ -n "${CI:-}" || "${CLAUDE_PETS_DMG_NO_FINDER:-}" == "1" ]] && use_finder=false

if $use_finder && ! osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {240, 140, $((240 + WIN_W)), $((140 + WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Claude Pets.app" of container window to {$APP_X, $ICON_Y}
    set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
then
  use_finder=false
  echo "Note: could not drive Finder. Falling back to the saved window layout."
  echo "      To refresh it, allow this terminal to control Finder"
  echo "      (System Settings > Privacy & Security > Automation) and re-run."
fi

if $use_finder; then
  # Keep the committed layout in step with what Finder just made.
  cp "$MOUNT/.DS_Store" "$LAYOUT" 2>/dev/null || true
elif [[ -f "$LAYOUT" ]]; then
  cp "$LAYOUT" "$MOUNT/.DS_Store"
else
  echo "Warning: no saved layout at $LAYOUT, so the DMG opens as a plain file list."
fi

# The mounted disk wears the crab too. This has to happen after Finder is done
# with the window: laying out the window wipes a .VolumeIcon.icns staged earlier.
cp Assets/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$DEV" >/dev/null || hdiutil detach "$DEV" -force >/dev/null

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$STAGE" "$RW"
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"

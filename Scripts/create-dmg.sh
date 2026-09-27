#!/bin/bash
# Package an already-built app. Finder writes the drag-to-install window layout.
# Usage: ./Scripts/create-dmg.sh [BeatSnap.app] [BeatSnap.dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${BEATSNAP_APP_PATH:-$ROOT/build/BeatSnap.app}}"
DMG="${2:-${BEATSNAP_DMG_PATH:-$(dirname "$APP")/BeatSnap.dmg}}"

if [ ! -d "$APP/Contents" ]; then
  echo "App bundle not found: $APP" >&2
  exit 1
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
mkdir -p "$(dirname "$DMG")"
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
APP_NAME="$(basename "$APP")"
if [[ "$DMG" != *.dmg || "$DMG" == "$APP/"* ]]; then
  echo "The DMG output must end in .dmg and be outside the app bundle." >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/beatsnap-dmg.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
MOUNT="$WORK/volume"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = "1" ]; then
    hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGING="$WORK/staging"
mkdir -p "$STAGING/.background" "$MOUNT"
ditto --noextattr --norsrc "$APP" "$STAGING/$APP_NAME"
# Finder can attach metadata to the source after signing; clean only our staged copy.
xattr -cr "$STAGING/$APP_NAME"
codesign --verify --deep --strict "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
swift "$ROOT/Scripts/dmg-background.swift" "$STAGING/.background/install.png"

# Leave room for Finder metadata even when the app's size changes.
SIZE_KB="$(( $(du -sk "$STAGING" | awk '{print $1}') + 32768 ))"
hdiutil create -quiet -srcfolder "$STAGING" -volname BeatSnap -fs HFS+ \
  -format UDRW -size "${SIZE_KB}k" "$WORK/writable.dmg"
MOUNTED=1
hdiutil attach -quiet -readwrite -noverify -nobrowse -mountpoint "$MOUNT" "$WORK/writable.dmg"

# Pass paths as arguments rather than interpolating them into AppleScript source.
# macOS may ask once for permission to control Finder. Fail visibly if it is denied.
osascript - "$MOUNT" "$APP_NAME" <<'APPLESCRIPT'
on run arguments
    set mountPath to item 1 of arguments
    set appName to item 2 of arguments
    set installFolder to POSIX file mountPath as alias
    tell application "Finder"
        set installFolder to item installFolder
        open installFolder
        set installerWindow to container window of installFolder
        set current view of installerWindow to icon view
        set toolbar visible of installerWindow to false
        set statusbar visible of installerWindow to false
        set pathbar visible of installerWindow to false
        set bounds of installerWindow to {160, 120, 800, 572}
        set viewOptions to icon view options of installerWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:install.png" of installFolder
        set position of item appName of installFolder to {170, 200}
        set position of item "Applications" of installFolder to {470, 200}
        update installFolder without registering applications
        delay 2
        close container window of installFolder
        delay 1
    end tell
end run
APPLESCRIPT

if [ ! -f "$MOUNT/.DS_Store" ]; then
  echo "Finder did not save the installer layout; no DMG was published." >&2
  exit 1
fi
# Finder may add FinderInfo while arranging the installer. Clean the app only,
# preserving the volume’s .DS_Store and installation background.
xattr -cr "$MOUNT/$APP_NAME"
codesign --verify --deep --strict "$MOUNT/$APP_NAME"
sync
hdiutil detach "$MOUNT" -quiet
MOUNTED=0
hdiutil convert -quiet "$WORK/writable.dmg" -format UDZO -imagekey zlib-level=9 \
  -o "$WORK/BeatSnap.dmg"
hdiutil verify -quiet "$WORK/BeatSnap.dmg"
# Keep any previous installer until packaging and verification have succeeded.
mv -f "$WORK/BeatSnap.dmg" "$DMG"
printf 'DMG ready: %s\n' "$DMG"

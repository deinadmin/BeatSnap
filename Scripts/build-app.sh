#!/bin/bash
#
# Assemble BeatSnap.app: build the Swift executable, bundle the command-line tools it needs
# (Python + yt-dlp + ffmpeg), write Info.plist, and sign.
# Pass --dmg to create the installer DMG; --notarize enables Developer ID distribution.
#
# The downloaded tools are cached in Scripts/.cache so repeat builds stay fast.

set -euo pipefail

CREATE_DMG=0
NOTARIZE=0
for option in "$@"; do
  case "$option" in
    --dmg) CREATE_DMG=1 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "Usage: $0 [--dmg] [--notarize]" >&2; exit 2 ;;
  esac
done
if [ "$NOTARIZE" = 1 ]; then
  : "${BEATSNAP_SIGNING_IDENTITY:?Set BEATSNAP_SIGNING_IDENTITY to your Developer ID Application certificate name}"
  : "${BEATSNAP_NOTARY_PROFILE:?Set BEATSNAP_NOTARY_PROFILE to a notarytool Keychain profile}"
  [[ "$BEATSNAP_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || {
    echo "Notarization requires a Developer ID Application identity." >&2; exit 1;
  }
  [ "${BEATSNAP_ENABLE_TEST_LICENSE:-0}" != 1 ] || {
    echo "Cannot notarize a build with test licenses enabled." >&2; exit 1;
  }
  # Fail before compiling if the certificate/private key or credentials are missing.
  echo "==> Checking Developer ID signing identity"
  if ! IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"; then
    printf 'Could not read signing identities from Keychain:\n%s\n' "$IDENTITIES" >&2
    exit 1
  fi
  if ! grep -F "\"$BEATSNAP_SIGNING_IDENTITY\"" <<< "$IDENTITIES" >/dev/null; then
    printf 'Signing identity not found: %s\n\nAvailable valid signing identities:\n%s\n\n' \
      "$BEATSNAP_SIGNING_IDENTITY" "$IDENTITIES" >&2
    echo 'Set BEATSNAP_SIGNING_IDENTITY to the exact Developer ID Application name shown above.' >&2
    echo 'If none are listed, check that the certificate and its private key are installed in an unlocked Keychain.' >&2
    echo 'In Keychain Access, look under My Certificates; the certificate should expand to show its private key.' >&2
    exit 1
  fi
  echo "==> Checking notarization Keychain profile"
  if ! NOTARY_CHECK="$(xcrun notarytool history --keychain-profile "$BEATSNAP_NOTARY_PROFILE" 2>&1)"; then
    printf 'Notarization profile check failed for "%s":\n%s\n' \
      "$BEATSNAP_NOTARY_PROFILE" "$NOTARY_CHECK" >&2
    echo 'Check the profile name, Keychain access, Apple credentials, and network connection.' >&2
    exit 1
  fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/Scripts/.cache"
BUILD="$ROOT/.build/release"
OUTPUT_APP="${BEATSNAP_APP_PATH:-$ROOT/build/BeatSnap.app}"
if [[ "$OUTPUT_APP" != /* ]]; then OUTPUT_APP="$ROOT/$OUTPUT_APP"; fi
# Assemble and sign away from Finder/File Provider-managed output directories.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/beatsnap-app.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
APP="$WORK/$(basename "$OUTPUT_APP")"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
TOOLS="$RESOURCES/tools"

APP_VERSION="${BEATSNAP_VERSION:-1.0.1}"
APP_BUILD="${BEATSNAP_BUILD:-1}"

YTDLP_VERSION="2026.07.04"
PYTHON_RELEASE="20260718"
PYTHON_VERSION="3.13.14"
FFMPEG_TAG="b6.1.1"

mkdir -p "$CACHE"

say() { printf "\033[1m==>\033[0m %s\n" "$1"; }

# ---------------------------------------------------------------- build

say "Building BeatSnapApp (release)"
cd "$ROOT"
if [ "${BEATSNAP_ENABLE_TEST_LICENSE:-0}" = "1" ]; then
  say "Enabling CARLO and TRIAL local test licenses — do not distribute this build"
  swift build -c release --product BeatSnapApp -Xswiftc -DBEATSNAP_TEST_LICENSE
else
  swift build -c release --product BeatSnapApp
fi

# ---------------------------------------------------------------- fetch tools

if [ ! -f "$CACHE/yt-dlp" ]; then
  say "Downloading yt-dlp $YTDLP_VERSION (zipapp)"
  curl -fsSL -o "$CACHE/yt-dlp" \
    "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp"
fi

if [ ! -d "$CACHE/python" ]; then
  say "Downloading CPython $PYTHON_VERSION (arm64, standalone)"
  curl -fsSL -o "$CACHE/python.tar.gz" \
    "https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/cpython-$PYTHON_VERSION+$PYTHON_RELEASE-aarch64-apple-darwin-install_only_stripped.tar.gz"
  tar xzf "$CACHE/python.tar.gz" -C "$CACHE"
  rm -f "$CACHE/python.tar.gz"

  # Trim what yt-dlp will never touch.
  PYLIB="$CACHE/python/lib/python${PYTHON_VERSION%.*}"
  rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/tkinter" "$PYLIB/lib2to3" \
         "$PYLIB/ensurepip" "$PYLIB/config-${PYTHON_VERSION%.*}-darwin" 2>/dev/null || true
  find "$CACHE/python" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
fi

if [ ! -f "$CACHE/ffmpeg" ]; then
  say "Downloading ffmpeg (arm64, static)"
  curl -fsSL -o "$CACHE/ffmpeg.gz" \
    "https://github.com/eugeneware/ffmpeg-static/releases/download/$FFMPEG_TAG/ffmpeg-darwin-arm64.gz"
  gunzip -f "$CACHE/ffmpeg.gz"
  chmod +x "$CACHE/ffmpeg"
fi

# ---------------------------------------------------------------- assemble

say "Assembling $OUTPUT_APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES" "$TOOLS"

cp "$BUILD/BeatSnapApp" "$CONTENTS/MacOS/BeatSnap"
chmod +x "$CONTENTS/MacOS/BeatSnap"

cp -R "$CACHE/python" "$TOOLS/python"
cp "$CACHE/yt-dlp" "$TOOLS/yt-dlp"
cp "$CACHE/ffmpeg" "$TOOLS/ffmpeg"
chmod +x "$TOOLS/yt-dlp" "$TOOLS/ffmpeg" "$TOOLS/python/bin/python3"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>BeatSnap</string>
    <key>CFBundleDisplayName</key>
    <string>BeatSnap</string>
    <key>CFBundleIdentifier</key>
    <string>com.carl.beatsnap</string>
    <key>CFBundleExecutable</key>
    <string>BeatSnap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <!-- Menubar-only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
    <!-- Makes Finder's "Open With > BeatSnap" appear for audio, which queues the file for
         analysis rather than playing it. Alternate rank so BeatSnap is never a candidate for
         *default* audio handler. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Licensing configuration is a client credential, never an admin token or private key.
LICENSE_CONFIG="${BEATSNAP_LICENSE_CONFIG:-$ROOT/Configuration/Cryptolens.plist}"
if [ -f "$LICENSE_CONFIG" ]; then
  plutil -lint "$LICENSE_CONFIG"
  cp "$LICENSE_CONFIG" "$RESOURCES/Cryptolens.plist"
else
  say "No Cryptolens configuration bundled"
fi

# ---------------------------------------------------------------- sign

SIGN_ARGS=(--force --sign - --timestamp=none)
if [ "$NOTARIZE" = 1 ]; then
  say "Signing with $BEATSNAP_SIGNING_IDENTITY"
  SIGN_ARGS=(--force --sign "$BEATSNAP_SIGNING_IDENTITY" --timestamp --options runtime)
else
  say "Ad-hoc signing"
fi
# Files copied from Finder-managed/downloaded locations can carry resource forks,
# FinderInfo, quarantine or provenance metadata. codesign rejects bundles containing
# those extended attributes, so strip them from the freshly assembled copy only. The
# cached source tools stay untouched.
xattr -cr "$APP"

# Nested tools first, then the bundle. The Python runtime loads its own .so files, so it
# needs library validation disabled to run under a signed parent.
ENTITLEMENTS="$WORK/entitlements.plist"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
</dict>
</plist>
ENT

# Inspect every regular file, including native libraries without executable bits.
find "$TOOLS" -type f -print0 > "$WORK/native-files"
while IFS= read -r -d '' file; do
  if file "$file" | grep -q "Mach-O"; then
    if [[ "$file" == "$TOOLS/python/bin/"* ]]; then
      codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$file"
    else
      codesign "${SIGN_ARGS[@]}" "$file"
    fi
  fi
done < "$WORK/native-files"

xattr -cr "$APP"
# Sign inside-out; --deep is for verification, not signing.
codesign "${SIGN_ARGS[@]}" "$APP"
rm -f "$ENTITLEMENTS"

say "Verifying"
codesign --verify --deep --strict "$APP"
echo "  signature ok"

if [ "$NOTARIZE" = 1 ]; then
  say "Notarizing app"
  if ! "$ROOT/Scripts/notarize.sh" "$APP"; then
    # Keep the signed bytes so a pending submission can be resumed without rebuilding.
    trap - EXIT
    printf 'Notarization did not complete. Signed app retained at: %s\n' "$APP" >&2
    printf 'Temporary build retained at: %s\n' "$WORK" >&2
    exit 1
  fi
fi

# Publish only the verified bundle. Do not copy resource forks or extended attributes.
mkdir -p "$(dirname "$OUTPUT_APP")"
rm -rf "$OUTPUT_APP"
ditto --noextattr --norsrc "$APP" "$OUTPUT_APP"
# Verify the published bytes through a clean local copy: File Providers may restore
# FinderInfo to the Desktop bundle immediately, even between xattr and codesign.
VERIFY_APP="$WORK/published/$(basename "$OUTPUT_APP")"
ditto --noextattr --norsrc "$OUTPUT_APP" "$VERIFY_APP"
xattr -cr "$VERIFY_APP"
codesign --verify --deep --strict "$VERIFY_APP"

# ---------------------------------------------------------------- installer
if [ "$CREATE_DMG" -eq 1 ]; then
  say "Creating drag-to-install DMG"
  BEATSNAP_NOTARIZE="$NOTARIZE" "$ROOT/Scripts/create-dmg.sh" "$OUTPUT_APP"
fi

SIZE="$(du -sh "$OUTPUT_APP" | cut -f1)"
say "Done: $OUTPUT_APP ($SIZE)"
echo
echo "  open \"$OUTPUT_APP\""

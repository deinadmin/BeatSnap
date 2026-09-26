#!/bin/bash
#
# Assemble BeatSnap.app: build the Swift executable, bundle the command-line tools it needs
# (Python + yt-dlp + ffmpeg), write Info.plist, and ad-hoc sign the result.
#
# The downloaded tools are cached in Scripts/.cache so repeat builds stay fast.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/Scripts/.cache"
BUILD="$ROOT/.build/release"
APP="${BEATSNAP_APP_PATH:-$ROOT/build/BeatSnap.app}"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
TOOLS="$RESOURCES/tools"

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
  say "Enabling CARLO local test license — do not distribute this build"
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

say "Assembling $APP"
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
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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

say "Ad-hoc signing"
# Files copied from Finder-managed/downloaded locations can carry resource forks,
# FinderInfo, quarantine or provenance metadata. codesign rejects bundles containing
# those extended attributes, so strip them from the freshly assembled copy only. The
# cached source tools stay untouched.
xattr -cr "$APP"

# Nested tools first, then the bundle. The Python runtime loads its own .so files, so it
# needs library validation disabled to run under a signed parent.
ENTITLEMENTS="$(mktemp -t beatsnap-ents).plist"
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

find "$TOOLS" -type f \( -perm -u+x -o -name "*.dylib" -o -name "*.so" \) -print0 \
  | while IFS= read -r -d '' file; do
      if file "$file" | grep -q "Mach-O"; then
        codesign --force --sign - --timestamp=none \
          --entitlements "$ENTITLEMENTS" "$file" 2>/dev/null || true
      fi
    done

codesign --force --deep --sign - --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP"
rm -f "$ENTITLEMENTS"

say "Verifying"
codesign --verify --deep --strict "$APP" && echo "  signature ok"

SIZE="$(du -sh "$APP" | cut -f1)"
say "Done: $APP ($SIZE)"
echo
echo "  open \"$APP\""

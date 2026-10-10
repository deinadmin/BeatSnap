#!/bin/bash
#
# Build BeatSnap, package the DMG, upload it to the website as a *draft* release, and open
# the draft in the admin so you can write the release notes and publish it.
#
#   ./Scripts/release.sh 1.2.0                     build and upload version 1.2.0
#   ./Scripts/release.sh 1.2.0 --build 42          set the build number (default: git commit count)
#   ./Scripts/release.sh 1.2.0 --notes "- Faster"  prefill the release notes
#   ./Scripts/release.sh 1.2.0 --skip-build        upload the existing build/BeatSnap.dmg
#   ./Scripts/release.sh 1.2.0 --dmg other.dmg     upload a specific DMG (implies --skip-build)
#   ./Scripts/release.sh 1.2.0 --min-os 26.0 --no-open
#
# Needs BEATSNAP_SITE_URL and BEATSNAP_API_TOKEN (Admin → Account → API Tokens) in
# Scripts/web.env. Re-running for a version that is still a draft replaces its file;
# published versions are refused.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${BEATSNAP_WEB_ENV:-$ROOT/Scripts/web.env}"

say() { printf "\033[1m==>\033[0m %s\n" "$1"; }
die() { printf "\033[31merror:\033[0m %s\n" "$1" >&2; exit 1; }
usage() { sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

VERSION=""
BUILD_NUMBER=""
NOTES=""
MIN_OS="26.0"
SKIP_BUILD=0
OPEN_EDITOR=1
DMG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build) BUILD_NUMBER="${2:?--build needs a value}"; shift 2 ;;
    --notes) NOTES="${2:?--notes needs a value}"; shift 2 ;;
    --min-os) MIN_OS="${2:?--min-os needs a value}"; shift 2 ;;
    --dmg) DMG="${2:?--dmg needs a path}"; SKIP_BUILD=1; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-open) OPEN_EDITOR=0; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [ -z "$VERSION" ] || usage; VERSION="$1"; shift ;;
  esac
done

[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}(-[0-9A-Za-z.-]+)?$ ]] || die "“$VERSION” isn’t a version like 1.2.0 or 1.3.0-beta.1."
if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"
fi

if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi
: "${BEATSNAP_SITE_URL:?Set BEATSNAP_SITE_URL in Scripts/web.env (see web.env.example)}"
: "${BEATSNAP_API_TOKEN:?Set BEATSNAP_API_TOKEN in Scripts/web.env — create one under Admin → Account}"
API="${BEATSNAP_SITE_URL%/}/api/releases.php"

json() { plutil -extract "$1" raw -o - - <<<"$2" 2>/dev/null || true; }

# Calls the API; sets STATUS and BODY. Extra arguments go straight to curl.
STATUS=""
BODY=""
api() {
  local response
  response="$(curl -sS --retry 2 -w $'\n%{http_code}' -H "X-BeatSnap-Token: $BEATSNAP_API_TOKEN" "$@")" \
    || die "Couldn’t reach $API"
  STATUS="${response##*$'\n'}"
  BODY="${response%$'\n'*}"
}
api_error() { json error "$BODY" | grep . || printf 'HTTP %s' "$STATUS"; }

# ---------------------------------------------------------------- preflight

say "Checking $BEATSNAP_SITE_URL"
api "$API?version=$VERSION"
[ "$STATUS" = 200 ] || die "The release API refused the request: $(api_error)"
CHUNK="$(json max_chunk_bytes "$BODY")"
[[ "$CHUNK" =~ ^[0-9]+$ ]] || die "Unexpected response from $API"
if [ "$(json release.published "$BODY")" = true ]; then
  die "Version $VERSION is already published. Bump the version, or unpublish it in the admin first."
elif [ -n "$(json release.id "$BODY")" ]; then
  say "Version $VERSION exists as a draft — its file will be replaced"
fi

# ---------------------------------------------------------------- build

APP="${BEATSNAP_APP_PATH:-$ROOT/build/BeatSnap.app}"
[[ "$APP" = /* ]] || APP="$ROOT/$APP"
if [ -z "$DMG" ]; then
  DMG="${BEATSNAP_DMG_PATH:-$(dirname "$APP")/BeatSnap.dmg}"
fi
[[ "$DMG" = /* ]] || DMG="$PWD/$DMG"

if [ "$SKIP_BUILD" = 0 ]; then
  say "Building BeatSnap $VERSION ($BUILD_NUMBER)"
  BEATSNAP_VERSION="$VERSION" BEATSNAP_BUILD="$BUILD_NUMBER" BEATSNAP_APP_PATH="$APP" BEATSNAP_DMG_PATH="$DMG" "$ROOT/Scripts/build-app.sh" --dmg --notarize
  BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  [ "$BUILT" = "$VERSION" ] || die "The built app reports version $BUILT, expected $VERSION."
elif [ -f "$APP/Contents/Info.plist" ] && [[ "$DMG" == "$(dirname "$APP")/"* ]]; then
  BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [ "$BUILT" = "$VERSION" ] || printf "\033[33mwarning:\033[0m the existing build is version %s, uploading it as %s\n" "$BUILT" "$VERSION"
fi
[ -f "$DMG" ] || die "DMG not found: $DMG"

# Existing DMGs must pass the same distribution checks before any upload.
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# ---------------------------------------------------------------- upload

SIZE="$(stat -f%z "$DMG")"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
UPLOAD_ID="$(openssl rand -hex 16)"
CHUNKS=$(( (SIZE + CHUNK - 1) / CHUNK ))
PIECE="$(mktemp "${TMPDIR:-/tmp}/beatsnap-chunk.XXXXXX")"
trap 'rm -f "$PIECE"' EXIT
MB() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'; }

say "Uploading $(basename "$DMG") ($(MB "$SIZE") MB in $CHUNKS chunk$([ "$CHUNKS" = 1 ] || echo s))"
for (( i = 0; i < CHUNKS; i++ )); do
  OFFSET=$(( i * CHUNK ))
  EXPECTED=$(( OFFSET + CHUNK < SIZE ? OFFSET + CHUNK : SIZE ))
  dd if="$DMG" of="$PIECE" bs="$CHUNK" skip="$i" count=1 2>/dev/null
  for attempt in 1 2 3 4; do
    api -F action=chunk -F "upload_id=$UPLOAD_ID" -F "offset=$OFFSET" -F "chunk=@$PIECE;filename=chunk.bin" "$API"
    [ "$STATUS" = 200 ] && [ "$(json received "$BODY")" = "$EXPECTED" ] && break
    [ "$attempt" = 4 ] && { echo; die "Chunk $((i + 1)) failed: $(api_error)"; }
    sleep $(( attempt * 2 ))
  done
  printf "\r    %3d%%  %s / %s MB" $(( EXPECTED * 100 / SIZE )) "$(MB "$EXPECTED")" "$(MB "$SIZE")"
done
echo

say "Creating draft"
api --form-string action=finish --form-string "upload_id=$UPLOAD_ID" \
  --form-string "file_name=$(basename "$DMG")" --form-string "size=$SIZE" --form-string "sha256=$SHA256" \
  --form-string "version=$VERSION" --form-string "build=$BUILD_NUMBER" --form-string "min_os=$MIN_OS" \
  --form-string "notes=$NOTES" "$API"
[[ "$STATUS" = 200 || "$STATUS" = 201 ]] || die "The server rejected the build: $(api_error)"
EDIT_URL="$(json edit_url "$BODY")"

printf "\n  \033[1mBeatSnap %s (%s)\033[0m is uploaded as a draft — not yet visible to visitors.\n" "$VERSION" "$BUILD_NUMBER"
printf "  SHA-256 %s\n\n" "$SHA256"
printf "  Add release notes and publish:\n  \033[4m%s\033[0m\n\n" "$EDIT_URL"
if [ "$OPEN_EDITOR" = 1 ]; then
  open "$EDIT_URL"
fi

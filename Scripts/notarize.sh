#!/bin/bash
# Submit an already Developer ID-signed app or DMG and staple its ticket.
set -euo pipefail
TARGET="${1:?Usage: notarize.sh /path/to/BeatSnap.app-or.dmg}"
: "${BEATSNAP_NOTARY_PROFILE:?Set BEATSNAP_NOTARY_PROFILE to a notarytool Keychain profile}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/beatsnap-notary.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Pass a previous submission ID as argument 2 to resume without uploading again.
ID="${2:-}"
if [ -z "$ID" ]; then
  case "$TARGET" in
    *.app)
      echo "==> Preparing app archive for Apple"
      codesign --verify --deep --strict "$TARGET"
      ditto -c -k --keepParent "$TARGET" "$WORK/submission.zip"
      SUBMISSION="$WORK/submission.zip"
      ;;
    *.dmg) SUBMISSION="$TARGET" ;;
    *) echo 'Expected an .app or .dmg' >&2; exit 2 ;;
  esac
  echo "==> Uploading to Apple (submission ID will appear below)"
  # Normal output displays upload progress; plist/json suppress it entirely.
  xcrun notarytool submit "$SUBMISSION" --keychain-profile "$BEATSNAP_NOTARY_PROFILE" \
    --no-wait --output-format normal --progress | tee "$WORK/upload.txt"
  ID="$(awk '$1 == "id:" { print $2; exit }' "$WORK/upload.txt")"
  if [ -z "$ID" ]; then
    echo 'Apple did not return a submission ID. Check notarytool history before retrying.' >&2
    exit 1
  fi
fi
printf '==> Waiting for Apple: %s (timeout %s)\n' "$ID" "${BEATSNAP_NOTARY_TIMEOUT:-30m}"
printf 'Check this submission in another terminal: xcrun notarytool info %q --keychain-profile %q\n' "$ID" "$BEATSNAP_NOTARY_PROFILE"
# A timeout stops local waiting; Apple continues processing the submission.
WAIT_RESULT=0
xcrun notarytool wait "$ID" --keychain-profile "$BEATSNAP_NOTARY_PROFILE" \
  --timeout "${BEATSNAP_NOTARY_TIMEOUT:-30m}" --output-format normal --progress || WAIT_RESULT=$?
xcrun notarytool info "$ID" --keychain-profile "$BEATSNAP_NOTARY_PROFILE" \
  --output-format plist > "$WORK/result.plist" || {
    echo "Could not retrieve status for submission $ID; check it before retrying." >&2
    exit 1
  }
STATUS="$(plutil -extract status raw -o - "$WORK/result.plist")"
printf 'Notarization: %s (submission %s)\n' "$STATUS" "$ID"
if [ "$STATUS" != Accepted ]; then
  if [ "$STATUS" = Invalid ] || [ "$STATUS" = Rejected ]; then
    xcrun notarytool log "$ID" --keychain-profile "$BEATSNAP_NOTARY_PROFILE" || true
  else
    printf 'Apple has not finished (wait exit status %s). No new submission is needed.\n' "$WAIT_RESULT" >&2
    printf 'Resume with: %q %q %q\n' "$0" "$TARGET" "$ID" >&2
  fi
  exit 1
fi
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
case "$TARGET" in
  *.app) spctl --assess --type execute --verbose=2 "$TARGET" ;;
  *.dmg) spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET" ;;
esac

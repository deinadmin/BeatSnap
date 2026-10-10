#!/bin/bash
#
# One-time setup for automatic updates. Creates the EdDSA key pair Sparkle uses to verify
# updates: the private key goes into your login Keychain (never into the repo), and the
# public key is added to Scripts/web.env so build-app.sh can embed it in the app.
#
# Back the private key up afterwards — losing it means existing installs can never be updated:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/beatsnap-sparkle-private-key
#   (store the file in a password manager, then delete it from the Desktop)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${BEATSNAP_WEB_ENV:-$ROOT/Scripts/web.env}"

TOOL="$(find "$ROOT/.build/artifacts" -path '*/bin/generate_keys' -not -path '*old_dsa*' 2>/dev/null | head -1)"
if [ ! -x "$TOOL" ]; then
  (cd "$ROOT" && swift package resolve)
  TOOL="$(find "$ROOT/.build/artifacts" -path '*/bin/generate_keys' -not -path '*old_dsa*' | head -1)"
fi

# Prints the existing public key if one is already in the Keychain, otherwise creates one.
OUTPUT="$("$TOOL")"
PUBLIC_KEY="$(printf '%s\n' "$OUTPUT" | sed -n 's|.*<string>\([A-Za-z0-9+/]\{43\}=\)</string>.*|\1|p' | head -1)"
[ -n "$PUBLIC_KEY" ] || { printf '%s\n' "$OUTPUT"; echo "Couldn’t read the public key above." >&2; exit 1; }

touch "$ENV_FILE"
if grep -q '^BEATSNAP_SPARKLE_PUBLIC_KEY=' "$ENV_FILE"; then
  sed -i '' "s|^BEATSNAP_SPARKLE_PUBLIC_KEY=.*|BEATSNAP_SPARKLE_PUBLIC_KEY=\"$PUBLIC_KEY\"|" "$ENV_FILE"
else
  printf '\nBEATSNAP_SPARKLE_PUBLIC_KEY="%s"\n' "$PUBLIC_KEY" >> "$ENV_FILE"
fi
echo "Public key saved to $ENV_FILE:"
echo "  $PUBLIC_KEY"
echo
echo "Next: back up the private key (see the comment at the top of this script)."

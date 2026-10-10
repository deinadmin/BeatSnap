#!/bin/bash
#
# Publish the website in Web/ to the FTP server configured in Scripts/web.env.
#
#   ./Scripts/deploy-web.sh             upload changes
#   ./Scripts/deploy-web.sh --dry-run   list what would change (lftp only)
#
# With lftp installed (brew install lftp) the remote folder is mirrored: only changed files
# are sent and files removed locally are removed remotely. Without it, curl uploads every
# file and nothing is deleted.
#
# Never touched on the server: storage/ (database + uploaded builds) and
# includes/config.local.php. Dev-only files (docker/, compose.yaml, README.md) are skipped.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/Web"
ENV_FILE="${BEATSNAP_WEB_ENV:-$ROOT/Scripts/web.env}"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

say() { printf "\033[1m==>\033[0m %s\n" "$1"; }
die() { printf "\033[31merror:\033[0m %s\n" "$1" >&2; exit 1; }

if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi
: "${FTP_URL:?Set FTP_URL in Scripts/web.env (see web.env.example)}"
: "${FTP_USER:?Set FTP_USER in Scripts/web.env}"
: "${FTP_PASSWORD:?Set FTP_PASSWORD in Scripts/web.env}"
FTP_URL="${FTP_URL%/}"
# Relative to the folder the FTP account logs into.
REMOTE_DIR="${FTP_REMOTE_DIR:-}"
REMOTE_DIR="${REMOTE_DIR#/}"
REMOTE_DIR="${REMOTE_DIR%/}"
REMOTE_DIR="${REMOTE_DIR:-.}"
INSECURE="${FTP_INSECURE:-0}"

CONFIG_FILE="${DEPLOY_CONFIG_FILE:-}"
if [ -n "$CONFIG_FILE" ]; then
  [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="$ROOT/$CONFIG_FILE"
  [ -f "$CONFIG_FILE" ] || die "DEPLOY_CONFIG_FILE not found: $CONFIG_FILE"
fi

# Paths relative to Web/ that are never uploaded (and, with lftp, never deleted remotely).
EXCLUDES=(
  "storage/"
  "docker/"
  "compose.yaml"
  "README.md"
  ".gitignore"
  "includes/config.local.php"
  ".DS_Store"
)

if command -v lftp >/dev/null 2>&1; then
  say "Mirroring Web/ to $FTP_URL/$REMOTE_DIR with lftp"
  args=(--reverse --delete --verbose=1 --parallel=4 --no-perms)
  [ "$DRY_RUN" = 1 ] && args+=(--dry-run)
  for pattern in "${EXCLUDES[@]}"; do
    case "$pattern" in
      */) args+=(--exclude "^${pattern//./\\.}") ;;
      *) args+=(--exclude-glob "$pattern") ;;
    esac
  done

  commands="set cmd:fail-exit yes
set net:max-retries 3
set net:timeout 30
set ftp:ssl-allow yes
set sftp:auto-confirm yes
set ssl:verify-certificate $([ "$INSECURE" = 1 ] && echo no || echo yes)
mkdir -p -f \"$REMOTE_DIR\"
mkdir -p -f \"$REMOTE_DIR/storage/releases\"
mirror ${args[*]} \"$WEB\" \"$REMOTE_DIR\"
put -O \"$REMOTE_DIR/storage\" \"$WEB/storage/.htaccess\""
  if [ -n "$CONFIG_FILE" ]; then
    commands+="
put \"$CONFIG_FILE\" -o \"$REMOTE_DIR/includes/config.local.php\""
  fi
  if [ "$DRY_RUN" = 1 ]; then
    commands="$(printf '%s\n' "$commands" | grep -v '^put \|^mkdir ')"
  fi

  LFTP_PASSWORD="$FTP_PASSWORD" lftp --env-password -u "$FTP_USER" "$FTP_URL" <<<"$commands"
else
  [ "$DRY_RUN" = 1 ] && die "--dry-run needs lftp (brew install lftp)."
  [[ "$FTP_URL" == sftp://* ]] && die "sftp:// needs lftp (brew install lftp)."
  say "Uploading Web/ to $FTP_URL/$REMOTE_DIR with curl (install lftp for incremental mirroring)"

  files=()
  while IFS= read -r -d '' file; do
    rel="${file#"$WEB"/}"
    skip=0
    for pattern in "${EXCLUDES[@]}"; do
      case "$pattern" in
        */) [[ "$rel" == "$pattern"* ]] && skip=1 ;;
        *) [[ "$rel" == "$pattern" || "$(basename "$rel")" == "$pattern" ]] && skip=1 ;;
      esac
    done
    [ "$skip" = 0 ] && files+=("$rel")
  done < <(find "$WEB" -type f -print0)
  files+=("storage/.htaccess" "storage/releases/.gitkeep")

  # One curl invocation reuses the connection for every file.
  args=(--fail --silent --show-error --ftp-create-dirs --retry 3 --user "$FTP_USER:$FTP_PASSWORD")
  [[ "$FTP_URL" == ftp://* ]] && args+=(--ssl)
  [ "$INSECURE" = 1 ] && args+=(--insecure)
  base="$FTP_URL/"
  [ "$REMOTE_DIR" = . ] || base+="$REMOTE_DIR/"
  for rel in "${files[@]}"; do
    args+=(-T "$WEB/$rel" "$base$rel")
  done
  if [ -n "$CONFIG_FILE" ]; then
    args+=(-T "$CONFIG_FILE" "${base}includes/config.local.php")
  fi
  curl "${args[@]}"
  say "Uploaded ${#files[@]} files"
fi

if [ "$DRY_RUN" = 0 ] && [ -n "${BEATSNAP_SITE_URL:-}" ]; then
  status="$(curl -s -o /dev/null -w '%{http_code}' "${BEATSNAP_SITE_URL%/}/")"
  if [ "$status" = 200 ]; then
    say "Live: ${BEATSNAP_SITE_URL%/}/"
  else
    die "The site answered HTTP $status after deploying — check ${BEATSNAP_SITE_URL%/}/"
  fi
fi

#!/usr/bin/env bash
# Launch PhotosApp against the Nextcloud drill.
#
# TCC note: a sandboxed app must be launched via LaunchServices (`open`) so it is its own
# "responsible process" — only then does the Photos permission prompt appear. Direct-exec from
# a shell attributes the request to Terminal and gets auto-denied. So: stage creds into the
# launchd session env (the app inherits them), `open` the bundle, tail the log, and scrub the
# env on exit. Creds live only in this user's launchd session and are unset when you Ctrl-C.
#
#   CREDS=~/micloud-drill-creds.env ./run.sh
#
# Creds file must define NEXTCLOUD_USER and NEXTCLOUD_PASS (as pulled from pve03).
set -euo pipefail
cd "$(dirname "$0")"

# Nextcloud creds (optional): CREDS=~/micloud-drill-creds.env
CREDS="${CREDS:-./nc-drill-creds.env}"
if [ -f "$CREDS" ]; then
  # shellcheck disable=SC1090
  set -a; . "$CREDS"; set +a
  : "${NEXTCLOUD_USER:?NEXTCLOUD_USER missing from creds file}"
  : "${NEXTCLOUD_PASS:?NEXTCLOUD_PASS missing from creds file}"
  DRILL_HOST="${DRILL_HOST:-DRILL_HOST}"
  NEXTCLOUD_URL="https://${DRILL_HOST}/remote.php/dav/files/${NEXTCLOUD_USER}/"
fi
# Immich creds (optional): IMMICH_CREDS=~/micloud-immich-drill-creds.env (defines IMMICH_URL + IMMICH_KEY)
IMMICH_CREDS="${IMMICH_CREDS:-}"
if [ -n "$IMMICH_CREDS" ] && [ -f "$IMMICH_CREDS" ]; then
  # shellcheck disable=SC1090
  set -a; . "$IMMICH_CREDS"; set +a
fi
[ -n "${NEXTCLOUD_URL:-}${IMMICH_URL:-}" ] || { echo "no targets: set CREDS and/or IMMICH_CREDS"; exit 1; }

APP="./PhotosApp.app"
[ -d "$APP" ] || { echo "app not built — run ./build.sh first"; exit 1; }
LOG="$HOME/Library/Containers/com.mineracks.micloud.photosapp/Data/micloud-photosapp.log"

scrub() { for v in NEXTCLOUD_URL NEXTCLOUD_USER NEXTCLOUD_PASS IMMICH_URL IMMICH_KEY; do launchctl unsetenv "$v"; done; }
trap scrub EXIT

[ -n "${NEXTCLOUD_URL:-}" ]  && { launchctl setenv NEXTCLOUD_URL "$NEXTCLOUD_URL"; launchctl setenv NEXTCLOUD_USER "$NEXTCLOUD_USER"; launchctl setenv NEXTCLOUD_PASS "$NEXTCLOUD_PASS"; }
[ -n "${IMMICH_URL:-}" ]     && { launchctl setenv IMMICH_URL "$IMMICH_URL"; launchctl setenv IMMICH_KEY "$IMMICH_KEY"; }

rm -f "$LOG" 2>/dev/null || true
echo "target : $NEXTCLOUD_URL"
echo "log    : $LOG"
echo
echo ">>> Click ALLOW on the 'PhotosApp would like to access Photos' prompt."
echo ">>> Watching the log — Ctrl-C to quit once you see 'initial test upload complete'."
echo
open "$APP"

# wait for the log to appear, then stream it
for _ in $(seq 1 40); do [ -f "$LOG" ] && break; sleep 0.5; done
tail -f "$LOG"

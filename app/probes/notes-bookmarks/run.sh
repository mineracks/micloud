#!/usr/bin/env bash
# Launch the Notes+Bookmarks probe against the Nextcloud drill.
#   CREDS=~/micloud-drill-creds.env ./run.sh
# Prereq: the app must be added to Full Disk Access (for Safari bookmarks). Notes prompts for Automation.
set -euo pipefail
cd "$(dirname "$0")"

CREDS="${CREDS:-./nc-drill-creds.env}"
[ -f "$CREDS" ] || { echo "creds file not found: $CREDS  (set CREDS=/path/to/nc-drill-creds.env)"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$CREDS"; set +a
: "${NEXTCLOUD_USER:?}"; : "${NEXTCLOUD_PASS:?}"
DRILL_HOST="${DRILL_HOST:-DRILL_HOST}"
NEXTCLOUD_URL="https://${DRILL_HOST}/remote.php/dav/files/${NEXTCLOUD_USER}/"

APP="./NotesBookmarks.app"
[ -d "$APP" ] || { echo "not built — run ./build.sh first"; exit 1; }
LOG="$HOME/micloud-notesbookmarks.log"

scrub() { for v in NEXTCLOUD_URL NEXTCLOUD_USER NEXTCLOUD_PASS NOTES_LIMIT; do launchctl unsetenv "$v" 2>/dev/null || true; done; }
trap scrub EXIT
launchctl setenv NEXTCLOUD_URL "$NEXTCLOUD_URL"
launchctl setenv NEXTCLOUD_USER "$NEXTCLOUD_USER"
launchctl setenv NEXTCLOUD_PASS "$NEXTCLOUD_PASS"
launchctl setenv NOTES_LIMIT "${NOTES_LIMIT:-25}"

rm -f "$LOG" 2>/dev/null || true
echo "target: $NEXTCLOUD_URL"
echo ">>> Grant Automation for Notes when prompted. Watching the log — Ctrl-C to stop."
echo
open "$APP"
for _ in $(seq 1 40); do [ -f "$LOG" ] && break; sleep 0.5; done
tail -f "$LOG"

#!/usr/bin/env bash
# Launch the micloud dashboard against the drills. Injects the drill creds into the launchd session
# (so the sandboxed app, launched via `open` for TCC, inherits them), then scrubs on exit.
#
#   CREDS=~/micloud-drill-creds.env IMMICH_CREDS=~/micloud-immich-drill-creds.env ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

CREDS="${CREDS:-}"
if [ -n "$CREDS" ] && [ -f "$CREDS" ]; then
  set -a; . "$CREDS"; set +a
  DRILL_HOST="${DRILL_HOST:-DRILL_HOST}"
  export NEXTCLOUD_URL="https://${DRILL_HOST}/remote.php/dav/files/${NEXTCLOUD_USER}/"
fi
IMMICH_CREDS="${IMMICH_CREDS:-}"
if [ -n "$IMMICH_CREDS" ] && [ -f "$IMMICH_CREDS" ]; then
  set -a; . "$IMMICH_CREDS"; set +a
fi

APP="./micloud.app"
[ -d "$APP" ] || { echo "not built — run ./build.sh first"; exit 1; }

scrub() { for v in NEXTCLOUD_URL NEXTCLOUD_USER NEXTCLOUD_PASS IMMICH_URL IMMICH_KEY MICLOUD_DRIVE MICLOUD_MORE BACKFILL_LIMIT CAPACITY_THRESHOLD; do launchctl unsetenv "$v" 2>/dev/null || true; done; }
trap scrub EXIT

[ -n "${NEXTCLOUD_URL:-}" ] && { launchctl setenv NEXTCLOUD_URL "$NEXTCLOUD_URL"; launchctl setenv NEXTCLOUD_USER "$NEXTCLOUD_USER"; launchctl setenv NEXTCLOUD_PASS "$NEXTCLOUD_PASS"; }
[ -n "${IMMICH_URL:-}" ]    && { launchctl setenv IMMICH_URL "$IMMICH_URL"; launchctl setenv IMMICH_KEY "$IMMICH_KEY"; }
# Enable the Documents/Drive source unless the caller set MICLOUD_DRIVE=0 (needs Nextcloud creds + a folder grant)
launchctl setenv MICLOUD_DRIVE "${MICLOUD_DRIVE:-1}"
# Optional: MICLOUD_MORE=1 → also request Calendars/Reminders/Contacts; plus test knobs, forwarded if set
launchctl setenv MICLOUD_MORE "${MICLOUD_MORE:-0}"
[ -n "${BACKFILL_LIMIT:-}" ]      && launchctl setenv BACKFILL_LIMIT "$BACKFILL_LIMIT"
[ -n "${CAPACITY_THRESHOLD:-}" ]  && launchctl setenv CAPACITY_THRESHOLD "$CAPACITY_THRESHOLD"

echo "targets: ${NEXTCLOUD_URL:+nextcloud }${IMMICH_URL:+immich}"
echo ">>> Grant Photos access when prompted, then pick an iCloud Drive folder for micloud to mirror."
open "$APP"
echo ">>> Launched. Leave it running; close the window to quit. (Ctrl-C here just scrubs the creds.)"
# keep the creds set briefly so the app reads them, then this script can exit (trap scrubs)
sleep 8

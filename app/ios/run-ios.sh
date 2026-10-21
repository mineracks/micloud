#!/usr/bin/env bash
# Boot a simulator, install the app, launch it with the drill creds (via SIMCTL_CHILD_*), screenshot.
#   CREDS=~/micloud-drill-creds.env ./run-ios.sh
set -euo pipefail
cd "$(dirname "$0")"
DEVICE="${DEVICE:-iPhone 17 Pro}"
BUNDLE="com.mineracks.micloud.phone"

CREDS="${CREDS:-$HOME/micloud-drill-creds.env}"
[ -f "$CREDS" ] || { echo "creds not found: $CREDS"; exit 1; }
set -a; . "$CREDS"; set +a
DRILL_HOST="${DRILL_HOST:-DRILL_HOST}"

xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" 2>/dev/null || true
[ -d MicloudPhone.app ] || { echo "not built — run ./build-ios.sh"; exit 1; }
xcrun simctl install booted MicloudPhone.app

export SIMCTL_CHILD_NEXTCLOUD_URL="https://${DRILL_HOST}/remote.php/dav/files/${NEXTCLOUD_USER}/"
export SIMCTL_CHILD_NEXTCLOUD_USER="$NEXTCLOUD_USER"
export SIMCTL_CHILD_NEXTCLOUD_PASS="$NEXTCLOUD_PASS"
xcrun simctl launch --terminate-running-process booted "$BUNDLE" >/dev/null
echo "launched; waiting for status fetch…"
sleep 6
xcrun simctl io booted screenshot phone-status.png >/dev/null 2>&1 && echo "screenshot: $(pwd)/phone-status.png"

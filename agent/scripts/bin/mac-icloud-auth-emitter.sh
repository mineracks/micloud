#!/bin/bash
# mac-icloud-auth-emitter.sh — hourly heartbeat for iCloud Photos delivery to Mac Studio.
#
# Why this exists: 2026-05-29 23:45 Apple's iCloud auth token expired on
# the headless Mac Studio. Nobody saw the GUI sign-in prompt. cloudphotod
# stopped downloading new originals for 48h. Both photo-sync pipelines
# (Immich + Nextcloud) kept running but reported "idle, no changes" the
# whole time because there was nothing new to mirror. Caught manually on
# 2026-05-31 by inspecting MobileMeAccounts.plist and finding
# MSNeedsPassword=1 hiding inside.
#
# But MSNeedsPassword is a STALE FLAG in the plist (mtime = last boot),
# not a live signal. It can persist as 1 even after the user re-auths.
# So instead of trusting the plist flag, we observe the symptom that
# every failure mode produces: the Photos library's originals/ tree
# stops receiving new files.
#
# Signal: hours since any originals/<single-char>/ subdir was last touched.
#   When iCloud Photos is delivering, the 16 one-char hash buckets get
#   their mtimes bumped within minutes-to-hours of new photos arriving.
#   When iCloud is paused for ANY reason — expired auth, quota full,
#   "Optimise Mac Storage" silently toggled on, cloudphotod crashed,
#   network down — the bucket mtimes freeze.
#
# Schema:
#   event=heartbeat hours_since_originals_touch=<N> cloudphotod=running|down needs_password_hint=0|1|-1
#   event=run_failed reason=...
#
# Sentinel: alerts when hours_since_originals_touch >= 12 for >1h.
# False-positive note: if you genuinely take zero new photos for 12h+
# (e.g. travelling without your phone), this fires. Acceptable trade-off
# vs the 48h silent break we just had.

set -uo pipefail
LOG_TAG=mac-icloud-auth
[ -f "$HOME/.config/micloud/config.env" ] && { set -a; . "$HOME/.config/micloud/config.env"; set +a; }
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
ORIGINALS="/Volumes/PhotosSSD/Photos Library.photoslibrary/originals"
PLIST="$HOME/Library/Preferences/MobileMeAccounts.plist"

loki_push() {
    local event="$1"
    local extra="${2:-}"
    local iso_ts
    iso_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local ns_ts
    ns_ts=$(python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null)
    [ -z "$ns_ts" ] && ns_ts="$(date +%s)000000000"
    local line="${iso_ts} ${event}${extra:+ ${extra}}"
    local payload
    payload="{\"streams\":[{\"stream\":{\"job\":\"mac_icloud_auth\",\"host\":\"mac-studio\",\"event\":\"${event}\"},\"values\":[[\"${ns_ts}\",\"${line}\"]]}]}"
    /usr/bin/curl --max-time 5 -s -X POST "$LOKI_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" -o /dev/null 2>&1 || true
}

if [ ! -d "$ORIGINALS" ]; then
    loki_push run_failed "reason=originals_dir_missing"
    exit 0
fi

# Newest mtime among the 16 single-char subdirs (each is a hash bucket).
newest_epoch=$(/usr/bin/find "$ORIGINALS" -maxdepth 1 -type d -mindepth 1 -exec /usr/bin/stat -f "%m" {} \; 2>/dev/null \
    | sort -nr | head -1)
if [ -z "${newest_epoch:-}" ]; then
    loki_push run_failed "reason=no_subdirs_in_originals"
    exit 0
fi
now_epoch=$(date +%s)
hours=$(( (now_epoch - newest_epoch) / 3600 ))

# Process state — secondary signal
if /usr/bin/pgrep -x cloudphotod >/dev/null 2>&1; then
    daemon=running
else
    daemon=down
fi

# Plist hint — stale flag, surfaced for diagnosis only, NOT alerting
needs_pw_hint=-1
if [ -r "$PLIST" ]; then
    needs_pw_hint=$(/usr/bin/plutil -convert json -o - "$PLIST" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for acct in d.get("Accounts", []):
        for svc in acct.get("Services", []):
            if svc.get("ServiceID") == "com.apple.Dataclass.Photos":
                print(int(svc.get("MSNeedsPassword", 0)))
                sys.exit(0)
    print(-1)
except Exception:
    print(-1)
' 2>/dev/null || echo -1)
fi

loki_push heartbeat "hours_since_originals_touch=${hours} cloudphotod=${daemon} needs_password_hint=${needs_pw_hint}"

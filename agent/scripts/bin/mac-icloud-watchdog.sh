#!/bin/bash
# ~/Library/Scripts/mac-icloud-watchdog.sh
#
# Self-healing watchdog for iCloud Photos delivery on the Mac Studio. Runs every
# 30 minutes via the com.mineracks.mac-icloud-watchdog LaunchAgent.
#
# Same originals/-mtime signal as mac-icloud-auth-emitter, but acts on it:
#   - hours_since >= 6 AND no recent kick → launchctl kickstart cloudphotod
#   - 3 consecutive kicks without recovery → emit auto_kick_giving_up
#     (this is the new condition for human escalation; rare)
#
# Each run posts to Loki under {job=mac_icloud_watchdog,host=mac-studio,event=...}
# so the kick history shows up in Grafana alongside mac_icloud_auth heartbeats.

set -uo pipefail

[ -f "$HOME/.config/micloud/config.env" ] && { set -a; . "$HOME/.config/micloud/config.env"; set +a; }
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
PHOTOS_LIB="/Volumes/PhotosSSD/Photos Library.photoslibrary"
ORIGINALS_DIR="${PHOTOS_LIB}/originals"
STATE_DIR="${HOME}/Library/Application Support/mac-icloud-watchdog"
LAST_KICK_FILE="${STATE_DIR}/last_kick_at"
KICK_COUNT_FILE="${STATE_DIR}/consecutive_kicks"

KICK_THRESHOLD_H=6
KICK_COOLDOWN_S=$((25 * 60))
MAX_CONSECUTIVE_KICKS=3

loki_push() {
    local event="$1"
    local extra="${2:-}"
    local iso_ts ns_ts line payload
    iso_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ns_ts=$(python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null)
    [ -z "$ns_ts" ] && ns_ts="$(date +%s)000000000"
    line="${iso_ts} ${event}${extra:+ ${extra}}"
    payload="{\"streams\":[{\"stream\":{\"job\":\"mac_icloud_watchdog\",\"host\":\"mac-studio\",\"event\":\"${event}\"},\"values\":[[\"${ns_ts}\",\"${line}\"]]}]}"
    /usr/bin/curl --max-time 5 -s -X POST "$LOKI_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" -o /dev/null 2>&1 || true
}

mkdir -p "$STATE_DIR" 2>/dev/null || true

# --- compute hours_since_originals_touch -----------------------------------

if [ ! -d "$ORIGINALS_DIR" ]; then
    loki_push run_failed "reason=originals_dir_missing"
    exit 0
fi

NEWEST_MTIME=$(/usr/bin/find "$ORIGINALS_DIR" -mindepth 1 -maxdepth 1 -type d \
    -exec /usr/bin/stat -f '%m' {} \; 2>/dev/null | sort -nr | head -1)

if [ -z "${NEWEST_MTIME:-}" ]; then
    loki_push run_failed "reason=no_originals_subdirs"
    exit 0
fi

NOW=$(date +%s)
HOURS_SINCE=$(( (NOW - NEWEST_MTIME) / 3600 ))

LAST_KICK_AT=$(cat "$LAST_KICK_FILE" 2>/dev/null || echo 0)
CONSECUTIVE=$(cat "$KICK_COUNT_FILE" 2>/dev/null || echo 0)
TIME_SINCE_KICK=$((NOW - LAST_KICK_AT))

# --- healthy path ----------------------------------------------------------

if [ "$HOURS_SINCE" -lt "$KICK_THRESHOLD_H" ]; then
    if [ "$CONSECUTIVE" -gt 0 ]; then
        loki_push heal_confirmed "hours_since=${HOURS_SINCE} consecutive_kicks_cleared=${CONSECUTIVE}"
        echo 0 > "$KICK_COUNT_FILE"
    else
        loki_push ok "hours_since=${HOURS_SINCE}"
    fi
    exit 0
fi

# --- stalled ---------------------------------------------------------------

if [ "$TIME_SINCE_KICK" -lt "$KICK_COOLDOWN_S" ]; then
    loki_push cooldown "hours_since=${HOURS_SINCE} time_since_kick=${TIME_SINCE_KICK}s threshold=${KICK_COOLDOWN_S}s"
    exit 0
fi

UID_VAL=$(id -u)
PID_BEFORE=$(/usr/bin/pgrep -x cloudphotod 2>/dev/null | head -1)
PID_BEFORE=${PID_BEFORE:-none}
NEW_COUNT=$((CONSECUTIVE + 1))

if [ "$NEW_COUNT" -gt "$MAX_CONSECUTIVE_KICKS" ]; then
    loki_push auto_kick_giving_up "hours_since=${HOURS_SINCE} consecutive_kicks=${CONSECUTIVE} max=${MAX_CONSECUTIVE_KICKS} pid=${PID_BEFORE}"
    exit 0
fi

/bin/launchctl kickstart -k "gui/${UID_VAL}/com.apple.cloudphotod" 2>/dev/null
sleep 3
PID_AFTER=$(/usr/bin/pgrep -x cloudphotod 2>/dev/null | head -1)
PID_AFTER=${PID_AFTER:-none}

echo "$NOW" > "$LAST_KICK_FILE"
echo "$NEW_COUNT" > "$KICK_COUNT_FILE"

loki_push auto_kick "hours_since=${HOURS_SINCE} consecutive_kicks=${NEW_COUNT} pid_before=${PID_BEFORE} pid_after=${PID_AFTER}"

#!/bin/bash
# icloud-drive-sync.sh — One-way mirror: iCloud Drive → Nextcloud
# Uses rclone sync (not copy) — deletions/renames/moves are mirrored.
# Deleted files go to .trash/<folder>-<date>/ on Nextcloud as a safety net.

set -eo pipefail

LOG="$HOME/icloud-drive-sync.log"
LOCKFILE="/tmp/icloud-drive-sync.lock"
[ -f "$HOME/.config/micloud/config.env" ] && { set -a; . "$HOME/.config/micloud/config.env"; set +a; }
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
TODAY=$(date +%Y%m%d)
export PATH="/opt/homebrew/bin:$PATH"

# Push a structured heartbeat line to Loki.
# Usage: loki_push <event> [extra_kvs]
# event must be one of: started|idle|uploaded|failed|locked
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
  payload="{\"streams\":[{\"stream\":{\"job\":\"icloud_drive_sync\",\"host\":\"mac-studio\",\"event\":\"${event}\",\"script\":\"drive-hourly\"},\"values\":[[\"${ns_ts}\",\"${line}\"]]}]}"
  curl --max-time 5 -s -X POST "$LOKI_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" -o /dev/null 2>&1 || true
}

# Extract the last "Transferred: <SIZE> / ..." line from a log file, return the LHS size.
last_transferred() {
  local logfile=$1
  { grep 'Transferred:' "$logfile" 2>/dev/null || true; } \
    | tail -1 \
    | sed -E 's/.*Transferred:[[:space:]]+([0-9.]+[[:space:]]+[KMGTPE]?i?B|[0-9]+[[:space:]]*B?).*/\1/' \
    | head -1
}

# Convert a size string like "1.234 MiB" or "0 B" or "0" to bytes.
to_bytes() {
  python3 -c '
import sys, re
s = sys.argv[1].strip() if len(sys.argv) > 1 else "0"
if not s or s == "0" or s == "0 B": print(0); sys.exit()
m = re.match(r"([0-9.]+)\s*([KMGT]?)i?B?", s)
if not m: print(0); sys.exit()
n, unit = float(m.group(1)), m.group(2) or ""
mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
print(int(n * mult.get(unit, 1)))
' "$1" 2>/dev/null || echo 0
}

# Returns "added=N changed=N deleted=N errors=N" given a log-region path.
extract_acd() {
  local log=$1
  local added changed deleted errors
  added=$(grep -cE ': Copied \(new\)' "$log" 2>/dev/null || true)
  changed=$(grep -cE ': Copied \(replaced existing\)' "$log" 2>/dev/null || true)
  deleted=$(grep -cE ': Moved \(server-side\) to:|: Moved to:|: Deleted$' "$log" 2>/dev/null || true)
  errors=$(grep -cE '^[0-9/: -]+ ERROR ' "$log" 2>/dev/null || true)
  echo "added=${added:-0} changed=${changed:-0} deleted=${deleted:-0} errors=${errors:-0}"
}

# Prevent overlapping runs
if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE")
    if kill -0 "$pid" 2>/dev/null; then
        loki_push locked
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

STAGE="init"
FAILURE_DIR="$HOME/icloud-sync-failures"
mkdir -p "$FAILURE_DIR"
# Per-run rclone log paths (timestamped, so concurrent or back-to-back runs
# do not clobber each others log; failure trap below archives whichever
# stage tripped before /tmp can evict).
RUN_TS=$(date +%Y%m%d-%H%M%S)
DESK_LOG="/tmp/rclone-icloud-desk-${RUN_TS}.log"
MISC_LOG="/tmp/rclone-icloud-misc-${RUN_TS}.log"
trap '
  _ec=$?
  rm -f "$LOCKFILE"
  if [ "$_ec" -ne 0 ]; then
    # Archive whatever stage logs we have so the diagnostic survives the
    # next runs overwrite. Persistent dir, 30-day retention swept below.
    archive="${FAILURE_DIR}/${RUN_TS}-stage-${STAGE}.log"
    {
      echo "# icloud-drive-sync failure"
      echo "# run_ts=${RUN_TS}"
      echo "# stage=${STAGE} exit=${_ec}"
      echo "# ----- desk log -----"
      [ -f "$DESK_LOG" ] && tail -200 "$DESK_LOG" || echo "(no desk log)"
      echo "# ----- misc log -----"
      [ -f "$MISC_LOG" ] && tail -200 "$MISC_LOG" || echo "(no misc log)"
    } > "$archive" 2>/dev/null
    loki_push failed "exit=$_ec stage=$STAGE archive=${archive##*/}"
    # Cleanup old archives (>30d) so the dir does not grow unbounded.
    find "$FAILURE_DIR" -type f -mtime +30 -delete 2>/dev/null || true
  fi
  # Per-run rclone logs are kept for 7 days for ad-hoc inspection then swept.
  find /tmp -maxdepth 1 -name 'rclone-icloud-*.log' -mtime +7 -delete 2>/dev/null || true
' EXIT

loki_push started

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Sync Desktop (full mirror — deletions moved to .trash)
STAGE="desktop-sync"
rclone sync ~/Desktop nextcloud:Desktop/ \
  --transfers 4 --backup-dir "nextcloud:.trash/Desktop-${TODAY}/" \
  --exclude "**/*.app/**" \
  --stats-one-line-date -v 2>&1 | tee "$DESK_LOG" > /dev/null

# Documents sync removed — handled exclusively by rclone-documents-sync.sh (15-min schedule)

# Sync iCloud Drive misc (Downloads, app folders)
STAGE="misc-sync"
rclone sync "$HOME/Library/Mobile Documents/com~apple~CloudDocs/" nextcloud:iCloud-Drive/ \
  --exclude "Desktop/**" --exclude "Documents/**" \
  --exclude "**/*.app/**" \
  --transfers 4 --backup-dir "nextcloud:.trash/iCloud-Drive-${TODAY}/" \
  --stats-one-line-date -v 2>&1 | tee "$MISC_LOG" > /dev/null

STAGE="reporting"

DESK_TX=$(last_transferred "$DESK_LOG")
MISC_TX=$(last_transferred "$MISC_LOG")

DESK_BYTES=$(to_bytes "${DESK_TX}")
MISC_BYTES=$(to_bytes "${MISC_TX}")

TOTAL_BYTES=$(( DESK_BYTES + MISC_BYTES ))

cat "$DESK_LOG" "$MISC_LOG" \
  > /tmp/rclone-icloud-all.log
ACD=$(extract_acd /tmp/rclone-icloud-all.log)
rm -f /tmp/rclone-icloud-all.log

MSG="${TS} Sync complete | Desktop: ${DESK_TX} | iCloud: ${MISC_TX}"
echo "$MSG" >> "$LOG"

if [ "$TOTAL_BYTES" -eq 0 ]; then
  loki_push idle "duration_s=$SECONDS $ACD"
else
  loki_push uploaded "bytes=$TOTAL_BYTES duration_s=$SECONDS exit=0 $ACD"
fi

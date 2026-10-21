#!/bin/bash
# rclone-documents-sync.sh — ongoing incremental sync of ~/Documents to nextcloud:Documents/
# Managed by launchd (~/Library/LaunchAgents/com.mineracks.rclone-documents-sync.plist), runs every 15 min.
# Wrapped in flock to prevent concurrent ticks from overlapping if a sync runs longer than 15 min.

set -euo pipefail

LOG="$HOME/Library/Logs/rclone-documents-sync-ongoing.log"
LOCK="/tmp/rclone-documents-sync.lock"
BACKUP_BASE="nextcloud:Backups"
[ -f "$HOME/.config/micloud/config.env" ] && { set -a; . "$HOME/.config/micloud/config.env"; set +a; }
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
export PATH="/opt/homebrew/bin:$PATH"

mkdir -p "$(dirname "$LOG")"

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
  payload="{\"streams\":[{\"stream\":{\"job\":\"icloud_drive_sync\",\"host\":\"mac-studio\",\"event\":\"${event}\",\"script\":\"documents-15m\"},\"values\":[[\"${ns_ts}\",\"${line}\"]]}]}"
  curl --max-time 5 -s -X POST "$LOKI_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" -o /dev/null 2>&1 || true
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

exec 9<>"$LOCK"
if ! /usr/bin/shlock -f "$LOCK" -p $$ 2>/dev/null && ! flock -n 9 2>/dev/null; then
    # macOS doesn't ship flock by default — fallback: noclobber check
    if [[ -f "${LOCK}.pid" ]]; then
        prev_pid=$(cat "${LOCK}.pid" 2>/dev/null || echo)
        if [[ -n "$prev_pid" ]] && kill -0 "$prev_pid" 2>/dev/null; then
            echo "$(date +%FT%T) [skip] previous run pid $prev_pid still in flight" >> "$LOG"
            loki_push locked
            exit 0
        fi
    fi
fi
echo $$ > "${LOCK}.pid"

STAGE="init"
trap '
  _ec=$?
  rm -f "${LOCK}.pid"
  if [ "$_ec" -ne 0 ]; then
    loki_push failed "exit=$_ec stage=$STAGE"
  fi
' EXIT

loki_push started

TS=$(date +%Y-%m-%d-%H%M%S)
echo "=========================================" >> "$LOG"
echo "$(date +%FT%T) [start] backup-dir=$BACKUP_BASE/$TS" >> "$LOG"

LOG_START_LINE=$(wc -l < "$LOG" 2>/dev/null || echo 0)

STAGE="rclone-sync"
rclone sync "$HOME/Documents" nextcloud:Documents/ \
    --webdav-nextcloud-chunk-size 5M \
    --transfers 4 \
    --retries 3 \
    --low-level-retries 5 \
    --exclude '.htaccess' \
    --exclude "**/*.app/**" \
    --backup-dir "$BACKUP_BASE/$TS" \
    --log-file "$LOG" \
    --stats 5m \
    --stats-log-level INFO \
    -v

STAGE="reporting"
echo "$(date +%FT%T) [done]" >> "$LOG"

TMPLOG=$(mktemp /tmp/rclone-docs-run.XXXXXX)
tail -n "+$((LOG_START_LINE + 1))" "$LOG" > "$TMPLOG"

TX=$({ grep 'Transferred:' "$TMPLOG" 2>/dev/null || true; } \
    | tail -1 \
    | sed -E 's/.*Transferred:[[:space:]]+([0-9.]+[[:space:]]+[KMGTPE]?i?B|[0-9]+[[:space:]]*B?).*/\1/' \
    | head -1)
TX_BYTES=$(to_bytes "${TX}")
ACD=$(extract_acd "$TMPLOG")
rm -f "$TMPLOG"

if [ "${TX_BYTES}" -eq 0 ]; then
  loki_push idle "duration_s=$SECONDS $ACD"
else
  loki_push uploaded "bytes=${TX_BYTES} duration_s=$SECONDS exit=0 $ACD"
fi

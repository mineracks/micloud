#!/bin/bash
# imessage-mirror-sync.sh — daily forward mirror of iMessage + SMS/MMS history to Nextcloud.
# Phase 8.1 of the iCloud sovereign-backup epic (roadmap/icloud-sovereign-backup).
#
# Runs ONLY on the Mac Studio: it is the only host signed into the iCloud account, so the
# only place ~/Library/Messages/chat.db is populated with full Messages-in-iCloud history.
#
# Strategy:
#   1. Online .backup of the live chat.db into a staging copy — the live DB is NEVER opened
#      for writing (read-only by construction; satisfies strict_oneway_sync_semantics).
#   2. Full export of the COPY with imessage-exporter -> styled per-conversation HTML plus
#      media converted to browser-friendly formats (HEIC->JPEG, MOV->MP4) via `-c full`.
#   3. `rclone copy --checksum` to nextcloud:Messages/iMessage/. imessage-exporter is
#      deterministic (byte-identical HTML for unchanged conversations), and --checksum
#      compares by content hash (not mtime), so a fresh full re-export transfers ONLY
#      conversations that gained new messages + genuinely new attachments.
#   `copy` (not `sync`) = append-only archive: a message deleted on the phone is NOT
#   removed from the mirror. This is intentional.
#
# Managed by launchd (~/Library/LaunchAgents/com.mineracks.imessage-mirror-sync.plist),
# daily. Single-instance guarded so a long run never overlaps the next tick.
#
# Observability: structured heartbeat to Loki under {job="imessage_mirror",host="mac-studio"}
# with event=started|idle|uploaded|failed|locked. Sentinel alert imessage-mirror-stale fires
# if no started/idle/uploaded in >36h (daily cadence + margin).

set -euo pipefail

STAGING="$HOME/imessage-mirror-staging"
EXPORT_DIR="$STAGING/full-html"
DBCOPY="$STAGING/chat-copy.db"
SRC_DB="$HOME/Library/Messages/chat.db"
REMOTE="nextcloud:Messages/iMessage/"
LOG="$HOME/Library/Logs/imessage-mirror-sync.log"
LOCK="/tmp/imessage-mirror-sync.lock"
[ -f "$HOME/.config/micloud/config.env" ] && { set -a; . "$HOME/.config/micloud/config.env"; set +a; }
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
export PATH="/opt/homebrew/bin:$PATH"

mkdir -p "$STAGING" "$(dirname "$LOG")"

# Push a structured heartbeat line to Loki.
# event must be one of: started|idle|uploaded|failed|locked
loki_push() {
  local event="$1"
  local extra="${2:-}"
  local iso_ts ns_ts line payload
  iso_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ns_ts=$(python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null)
  [ -z "$ns_ts" ] && ns_ts="$(date +%s)000000000"
  line="${iso_ts} ${event}${extra:+ ${extra}}"
  payload="{\"streams\":[{\"stream\":{\"job\":\"imessage_mirror\",\"host\":\"mac-studio\",\"event\":\"${event}\",\"script\":\"imessage-daily\"},\"values\":[[\"${ns_ts}\",\"${line}\"]]}]}"
  curl --max-time 5 -s -X POST "$LOKI_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" -o /dev/null 2>&1 || true
}

# Convert an rclone size string like "1.234 MiB" / "0 B" / "0" to bytes.
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

# Single-instance guard (macOS ships no flock; mirror the rclone-documents-sync pattern).
if [[ -f "${LOCK}.pid" ]]; then
  prev_pid=$(cat "${LOCK}.pid" 2>/dev/null || echo)
  if [[ -n "$prev_pid" ]] && kill -0 "$prev_pid" 2>/dev/null; then
    echo "$(date +%FT%T) [skip] previous run pid $prev_pid still in flight" >> "$LOG"
    loki_push locked
    exit 0
  fi
fi
echo $$ > "${LOCK}.pid"

STAGE="init"
trap '
  _ec=$?
  rm -f "${LOCK}.pid" "$DBCOPY"
  if [ "$_ec" -ne 0 ]; then
    loki_push failed "exit=$_ec stage=$STAGE"
  fi
' EXIT

loki_push started
echo "=========================================" >> "$LOG"
echo "$(date +%FT%T) [start]" >> "$LOG"

# 1. Consistent read-only snapshot of the live Messages DB.
STAGE="db-backup"
sqlite3 "$SRC_DB" ".backup '$DBCOPY'"

# 2. Full export -> HTML + converted media into a clean dir.
STAGE="export"
rm -rf "$EXPORT_DIR"
imessage-exporter -f html -o "$EXPORT_DIR" -c full -p "$DBCOPY" >> "$LOG" 2>&1

# 3. Delta upload by content hash (only changed conversations + new media move).
STAGE="rclone-copy"
LOG_START_LINE=$(wc -l < "$LOG" 2>/dev/null || echo 0)
rclone copy "$EXPORT_DIR" "$REMOTE" \
    --checksum \
    --transfers 4 \
    --retries 3 \
    --low-level-retries 10 \
    --webdav-nextcloud-chunk-size 50M \
    --log-file "$LOG" \
    --stats 5m \
    --stats-log-level INFO \
    -v

# 4. Report.
STAGE="reporting"
echo "$(date +%FT%T) [done]" >> "$LOG"
TMPLOG=$(mktemp /tmp/imessage-sync-run.XXXXXX)
tail -n "+$((LOG_START_LINE + 1))" "$LOG" > "$TMPLOG"

TX=$({ grep 'Transferred:' "$TMPLOG" 2>/dev/null || true; } \
    | tail -1 \
    | sed -E 's/.*Transferred:[[:space:]]+([0-9.]+[[:space:]]+[KMGTPE]?i?B|[0-9]+[[:space:]]*B?).*/\1/' \
    | head -1)
TX_BYTES=$(to_bytes "${TX}")
COPIED=$(grep -cE ': Copied \(new\)|: Copied \(replaced existing\)' "$TMPLOG" 2>/dev/null || true)
CONVOS=$(ls "$EXPORT_DIR" 2>/dev/null | grep -c '\.html$' || true)
rm -f "$TMPLOG"

if [ "${TX_BYTES:-0}" -eq 0 ]; then
  loki_push idle "duration_s=$SECONDS conversations=${CONVOS:-0} copied=0"
else
  loki_push uploaded "bytes=${TX_BYTES} duration_s=$SECONDS copied=${COPIED:-0} conversations=${CONVOS:-0}"
fi

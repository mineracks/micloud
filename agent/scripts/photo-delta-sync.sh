#!/bin/bash
# photo-delta-sync.sh — Phase 2.6 (Photos): new iCloud photos -> Immich + Nextcloud,
# "Optimise Mac Storage"-compatible. Part of the icloud-sovereign-backup epic.
#
# osxphotos exports a FRESH temp dir of photos taken since (checkpoint - buffer), with
# --download-missing so dataless (Optimise-evicted) originals are materialised on demand,
# then `immich upload` (dedup by hash) + rclone copy to the nextcloud-photos remote, advances
# the date checkpoint, and deletes the temp dir — nothing accumulates locally, the library
# stays thin on Optimise. The look-back buffer + Immich/rclone dedup absorb offline-sync lag;
# a weekly wide run (BUFFER_DAYS large, via a separate launchd job) mops up stragglers.
#
# Replaces the Download-Originals-era immich-photo-sync.sh / nextcloud-photo-sync.sh, which read
# originals/ directly and break on an Optimise library. Verified 2026-07-04: osxphotos export
# --download-missing on the fresh internal library reports missing:0 (materialises on demand).
set -uo pipefail
# load per-instance config (nothing hardcoded); shell sources the same file Python reads
MICLOUD_CONFIG="${MICLOUD_CONFIG:-$HOME/.config/micloud/config.env}"
[ -f "$MICLOUD_CONFIG" ] && { set -a; . "$MICLOUD_CONFIG"; set +a; }
LIB="${MICLOUD_PHOTOS_LIBRARY:-$HOME/Pictures/Photos Library.photoslibrary}"
CKPT_DIR="$HOME/.config/photo-delta-sync"; CKPT="$CKPT_DIR/checkpoint"
OSXPHOTOS="${MICLOUD_OSXPHOTOS:-/opt/homebrew/bin/osxphotos}"
IMMICH="${MICLOUD_IMMICH:-/opt/homebrew/bin/immich}"
RCLONE="${MICLOUD_RCLONE:-/opt/homebrew/bin/rclone}"
NC_REMOTE="${MICLOUD_NC_PHOTOS_REMOTE:-nextcloud-photos}"; NC_PATH="${MICLOUD_NC_PHOTOS_PATH:-Photos/iCloud-Camera}"
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
HOST_LABEL="${MICLOUD_HOST_LABEL:-mac-studio}"
LOG="$HOME/photo-delta-sync.log"
BUFFER_DAYS="${1:-2}"          # look-back buffer; pass a large value for the weekly mop-up
export PATH=/opt/homebrew/bin:$PATH
mkdir -p "$CKPT_DIR"

loki_push() {
  local ev="$1" extra="${2:-}"
  local ns; ns=$(python3 -c 'import time;print(int(time.time()*1e9))' 2>/dev/null || echo "$(date +%s)000000000")
  local iso; iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local payload="{\"streams\":[{\"stream\":{\"job\":\"photo_delta_sync\",\"host\":\"${HOST_LABEL}\",\"event\":\"${ev}\",\"script\":\"photo-delta\"},\"values\":[[\"${ns}\",\"${iso} ${ev} ${extra}\"]]}]}"
  curl --max-time 5 -s -X POST "$LOKI_URL" -H "Content-Type: application/json" -d "$payload" -o /dev/null 2>&1 || true
}

# atomic mkdir lock (macOS has no flock); reclaim if a prior run left it >2h ago
LOCKD="/tmp/photo-delta-sync.lockd"
[ -d "$LOCKD" ] && [ -n "$(find "$LOCKD" -maxdepth 0 -mmin +120 2>/dev/null)" ] && rm -rf "$LOCKD"
if ! mkdir "$LOCKD" 2>/dev/null; then loki_push locked; exit 0; fi
STAGE=$(mktemp -d /tmp/photo-delta.XXXXXX)
trap 'rm -rf "$LOCKD" "$STAGE"' EXIT
loki_push started "buffer_days=$BUFFER_DAYS"

# checkpoint = last run's date; default 5d back on first run to cover the SSD-stall gap
CKPT_DATE=$(cat "$CKPT" 2>/dev/null || date -v-5d +%Y-%m-%d)
FROM=$(python3 -c 'import datetime,sys; d=datetime.date.fromisoformat(sys.argv[1]); print((d-datetime.timedelta(days=int(sys.argv[2]))).isoformat())' "$CKPT_DATE" "$BUFFER_DAYS" 2>/dev/null || echo "$CKPT_DATE")
NOW=$(date +%Y-%m-%d)

# osxphotos export with retry (Photos.app holds an exclusive lock at intervals)
ok=0
for a in 1 2 3; do
  if $OSXPHOTOS export "$STAGE" --library "$LIB" --from-date "$FROM" --download-missing --no-progress >>"$LOG" 2>&1; then ok=1; break; fi
  sleep 25
done
[ "$ok" -ne 1 ] && { loki_push failed "osxphotos export failed from=$FROM"; exit 1; }

N=$(find "$STAGE" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
BYTES=0; up_ok=1
if [ "$N" -gt 0 ]; then
  BYTES=$(du -sk "$STAGE" 2>/dev/null | awk '{print $1*1024}')
  $IMMICH upload --recursive "$STAGE" >>"$LOG" 2>&1 || { up_ok=0; loki_push failed "immich upload error"; }
  $RCLONE copy "$STAGE" "$NC_REMOTE:$NC_PATH/$(date +%Y)/" --exclude ".*" >>"$LOG" 2>&1 || { up_ok=0; loki_push failed "rclone error"; }
fi
# Advance the checkpoint ONLY when the uploads succeeded (or there was nothing to upload) — a failed
# run leaves the window so the next run retries it, rather than silently skipping those photos.
if [ "$up_ok" -eq 1 ]; then echo "$NOW" > "$CKPT"; fi
# Library size = the Optimise-managed thin cache. --download-missing materialises originals INTO the
# library and Photos has no per-file evict, so it re-thins only via Optimise (under disk pressure).
# In practice new photos are already local so the hourly run rarely materialises; watch this trend.
LIBGB=$(du -sk "$LIB" 2>/dev/null | awk '{printf "%.1f", $1/1048576}')
if [ "$N" -eq 0 ]; then EV=idle; elif [ "$up_ok" -eq 1 ]; then EV=synced; else EV=failed; fi
loki_push "$EV" "exported=$N bytes=$BYTES from=$FROM checkpoint_advanced=$up_ok library_gb=$LIBGB"

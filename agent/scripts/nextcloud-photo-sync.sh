#!/bin/bash
# nextcloud-photo-sync.sh — Forward-only iCloud Photos -> Nextcloud mirror
# Phase 1.5 of the iCloud sovereign backup epic.
#
# Pulls photos with capture date >= FROM_DATE from the Mac Studio
# Photos.app library (Mac Studio's local copy of iCloud Photos) into a
# staging dir on /Volumes/PhotosSSD, then rclone-copies the diff into
# Nextcloud at Photos/iCloud-Camera/{YYYY}/{YYYY-MM}/.
#
# Independent of immich-photo-sync.sh:
#   - separate manifest (osxphotos's own export-state)
#   - separate launchd unit (com.mineracks.nextcloud-photo-sync)
#   - separate Loki job  (job=nextcloud_photos_sync)
#   - separate rclone remote (nextcloud-photos)
#   - separate destination path (Photos/iCloud-Camera/...)
# A failure or rollback on either side cannot affect the other.
#
# Source of truth: applications/icloud-sync/scripts/nextcloud-photo-sync.sh in
# the mineracks-infrastructure repo. Deploy with `scp` to ~/bin/ on Mac Studio.

set -uo pipefail
# Note: NOT set -e. We manage failures explicitly so the EXIT trap can emit
# a structured Loki `failed` event with the stage that broke.

LOG="$HOME/nextcloud-photo-sync.log"
LOCKFILE="/tmp/nextcloud-photo-sync.lock"
PHOTOS_LIB="/Volumes/PhotosSSD/Photos Library.photoslibrary"
STAGING_DIR="/Volumes/PhotosSSD/nextcloud-photo-sync-staging"
REPORT_DIR="$HOME/Library/Logs/nextcloud-photo-sync"
ENV_FILE="$HOME/.config/nextcloud-photo-sync/env"
[ -f "$HOME/.config/micloud/config.env" ] && { set -a; . "$HOME/.config/micloud/config.env"; set +a; }
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
OSXPHOTOS="/opt/homebrew/bin/osxphotos"
RCLONE="/opt/homebrew/bin/rclone"
FROM_DATE="2026-05-08"   # Forward-only cutoff; older photos remain in Immich only.
RCLONE_REMOTE="nextcloud-photos"
RCLONE_DEST="$RCLONE_REMOTE:Photos/iCloud-Camera"
export PATH="/opt/homebrew/bin:$PATH"

mkdir -p "$STAGING_DIR" "$REPORT_DIR"

# ------------------- Loki heartbeat -------------------
# Push a structured heartbeat line to Loki.
# Usage: loki_push <event> [extra_kvs]
# event: started|idle|uploaded|failed|locked|retrying|retry_ok|dryrun
loki_push() {
  local event="$1" extra="${2:-}"
  local iso_ts ns_ts line payload
  iso_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ns_ts=$(python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null)
  [ -z "$ns_ts" ] && ns_ts="$(date +%s)000000000"
  line="${iso_ts} ${event}${extra:+ ${extra}}"
  payload="{\"streams\":[{\"stream\":{\"job\":\"nextcloud_photos_sync\",\"host\":\"mac-studio\",\"event\":\"${event}\"},\"values\":[[\"${ns_ts}\",\"${line}\"]]}]}"
  curl --max-time 5 -s -X POST "$LOKI_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" -o /dev/null 2>&1 || true
}

# ------------------- Lock -------------------
if [ -f "$LOCKFILE" ]; then
  pid=$(cat "$LOCKFILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Sync already running (PID $pid), skipping" >> "$LOG"
    loki_push locked
    exit 0
  fi
fi
echo $$ > "$LOCKFILE"

# Failure trap fires on any non-zero exit after lock acquisition.
STAGE="init"
_LOKI_PUSHED=0
trap '
  _ec=$?
  rm -f "$LOCKFILE"
  if [ "$_ec" -ne 0 ] && [ "$_LOKI_PUSHED" != "1" ]; then
    loki_push failed "exit=$_ec stage=$STAGE"
  fi
' EXIT

loki_push started

# ------------------- Pre-flight -------------------
STAGE="preflight"
if [ ! -d "$PHOTOS_LIB" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: Photos Library not found at $PHOTOS_LIB" >> "$LOG"
  exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: env file missing at $ENV_FILE" >> "$LOG"
  exit 1
fi

# ------------------- osxphotos export (with retry on Photos.app lock) -------------------
# osxphotos opens the .photoslibrary bundle. Photos.app holds an exclusive
# lock at regular intervals; concurrent osxphotos against locked library
# returns nonzero. Retry up to 3 times with backoff.
STAGE="osxphotos-export"
REPORT_JSON="$REPORT_DIR/osxphotos-report-$(date +%s).json"

OSXPHOTOS_EC=1
# NOTE: --download-missing intentionally omitted. Mac Studio is in
# "Download Originals" mode (per Phase 1 runbook), so originals are
# already on disk by the time osxphotos sees them. With --download-missing
# enabled, osxphotos invokes AppleScript to ask Photos.app to download
# missing originals — when Photos.app is not running, that AppleScript
# call hangs indefinitely (observed 2026-05-08, 35-min hang on a
# zero-match scan). The Phase-1 (immich-photo-sync) pipeline doesn't use
# this flag either; same reasoning applies.
for attempt in 1 2 3; do
  # --touch-file: set each exported file's mtime to its photo capture date
  # (EXIF DateTimeOriginal where available, else Photos library "added" date).
  # Required because NC's Photos timeline orders by oc_filecache.mtime — and
  # NC's metadata extractor doesn't reliably read EXIF DateTimeOriginal from
  # HEIC files, falling back to file mtime. Without --touch-file, photos
  # appear in upload order rather than capture order.
  "$OSXPHOTOS" export \
    --library "$PHOTOS_LIB" \
    --from-date "$FROM_DATE" \
    --update \
    --skip-original-if-edited \
    --touch-file \
    --directory "{created.year}/{created.year}-{created.mm}" \
    --filename "{original_name}" \
    --report "$REPORT_JSON" \
    --retry 2 \
    "$STAGING_DIR" >> "$LOG" 2>&1
  OSXPHOTOS_EC=$?
  if [ "$OSXPHOTOS_EC" -eq 0 ]; then
    [ "$attempt" -gt 1 ] && loki_push retry_ok "osxphotos succeeded on attempt $attempt"
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    loki_push retrying "osxphotos exit=$OSXPHOTOS_EC on attempt $attempt — sleeping 30s"
    sleep 30
  fi
done

if [ "$OSXPHOTOS_EC" -ne 0 ]; then
  _LOKI_PUSHED=1
  loki_push failed "osxphotos failed after 3 attempts exit=$OSXPHOTOS_EC stage=$STAGE"
  exit "$OSXPHOTOS_EC"
fi

# Parse counts from the JSON report.
COUNTS=$(python3 <<PY
import json, sys
n=u=s=e=0
try:
    with open("$REPORT_JSON") as f:
        rows = json.load(f)
    for row in rows if isinstance(rows, list) else []:
        if row.get("error"): e += 1
        if row.get("exported"):
            if row.get("updated"): u += 1
            elif row.get("new"): n += 1
        if row.get("skipped"): s += 1
except Exception:
    pass
print(f"{n} {u} {s} {e}")
PY
)
read -r NEW_COUNT UPDATED_COUNT SKIPPED_COUNT ERROR_COUNT <<< "${COUNTS:-0 0 0 0}"
NEW_COUNT=${NEW_COUNT:-0}
UPDATED_COUNT=${UPDATED_COUNT:-0}
SKIPPED_COUNT=${SKIPPED_COUNT:-0}
ERROR_COUNT=${ERROR_COUNT:-0}

# ------------------- Fix JPG EXIF timezone for NC timeline -------------------
# NC reads DateTimeOriginal from JPGs and interprets it as UTC, but the tag
# stores local capture time (no TZ offset). --touch-file sets mtime to correct
# UTC. Overwrite DateTimeOriginal+CreateDate with the mtime value so NC sorts
# correctly. HEICs are unaffected (NC falls back to mtime for those).
# Modifying EXIF changes the file hash, so rclone --checksum will re-upload
# affected files once; subsequent runs skip (EXIF already matches mtime).
STAGE="exif-fix"
JPG_FIXED=0
if command -v exiftool >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    mtime_epoch=$(stat -f %m "$f")
    mtime_fmt=$(date -r "$mtime_epoch" -u +"%Y:%m:%d %H:%M:%S")
    exif_dt=$(exiftool -s3 -DateTimeOriginal "$f" 2>/dev/null)
    if [ -n "$exif_dt" ] && [ "$exif_dt" != "$mtime_fmt" ]; then
      exiftool -overwrite_original \
        -DateTimeOriginal="$mtime_fmt" \
        -CreateDate="$mtime_fmt" \
        "$f" >/dev/null 2>&1
      touch -t "$(date -r "$mtime_epoch" +%Y%m%d%H%M.%S)" "$f"
      JPG_FIXED=$((JPG_FIXED + 1))
    fi
  done < <(find "$STAGING_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -print0)
fi
[ "$JPG_FIXED" -gt 0 ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) EXIF-fix: corrected $JPG_FIXED JPG timestamps" >> "$LOG"

# ------------------- DRY_RUN short-circuit -------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  loki_push dryrun "DRY RUN: osxphotos new=$NEW_COUNT updated=$UPDATED_COUNT skipped=$SKIPPED_COUNT errors=$ERROR_COUNT (rclone NOT called) elapsed=${SECONDS}s new=$NEW_COUNT updated=$UPDATED_COUNT errors=$ERROR_COUNT"
  exit 0
fi

# ------------------- rclone copy staging -> Nextcloud -------------------
STAGE="rclone-copy"
RCLONE_LOG="$REPORT_DIR/rclone-$(date +%s).log"

# `rclone copy` (not sync) — never deletes on the remote even if a local
# file is removed. We're additive-only; manual deletions on iCloud should
# not propagate destructively to Nextcloud.
#
# --checksum: compare by hash instead of size+mtime. osxphotos --touch-file
# resets the staging file's mtime to the photo's capture date on every
# `--update` run. Without --checksum, rclone treats every re-touched file
# as "changed" and re-uploads it even though the bytes are identical —
# which made the `transferred=N` heartbeat report dozens of phantom
# uploads per day (33 over 24h vs 6 truly new). Slower (HEIC checksumming
# on a large staging set), but eliminates the phantom transfers entirely.
"$RCLONE" copy "$STAGING_DIR" "$RCLONE_DEST" \
  --checksum \
  --transfers 4 \
  --checkers 8 \
  --no-traverse \
  --user-agent "nextcloud-photo-sync/1.0" \
  --stats=0 \
  --log-level INFO \
  --log-file "$RCLONE_LOG" >> "$LOG" 2>&1
RCLONE_EC=$?

if [ "$RCLONE_EC" -ne 0 ]; then
  _LOKI_PUSHED=1
  loki_push failed "rclone exit=$RCLONE_EC stage=$STAGE log=$RCLONE_LOG osx_new=$NEW_COUNT osx_updated=$UPDATED_COUNT errors=$ERROR_COUNT"
  exit "$RCLONE_EC"
fi

TRANSFERRED=$(grep -cE 'INFO  : .+: Copied' "$RCLONE_LOG" 2>/dev/null || true)
TRANSFERRED=${TRANSFERRED:-0}

# ------------------- Heartbeat -------------------
TOTAL_NEW=$((NEW_COUNT + UPDATED_COUNT))
if [ "$TOTAL_NEW" -eq 0 ] && [ "$TRANSFERRED" -eq 0 ]; then
  loki_push idle "No changes detected (took ${SECONDS}s) new=0 updated=0 transferred=0 errors=$ERROR_COUNT"
else
  loki_push uploaded "Sync complete: exported $NEW_COUNT new + $UPDATED_COUNT updated; rclone transferred $TRANSFERRED files (${SECONDS}s) new=$NEW_COUNT updated=$UPDATED_COUNT transferred=$TRANSFERRED errors=$ERROR_COUNT"
fi

# Cleanup old reports (keep last 30 days)
find "$REPORT_DIR" -name 'osxphotos-report-*.json' -mtime +30 -delete 2>/dev/null || true
find "$REPORT_DIR" -name 'rclone-*.log' -mtime +30 -delete 2>/dev/null || true

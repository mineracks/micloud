#!/bin/bash
# immich-photo-sync.sh — Incremental photo sync to Immich
# Triggered by launchd WatchPaths when Photos Library changes
# Pushes sync events to Loki for monitoring in Grafana

LOG="$HOME/immich-sync.log"
LOCKFILE="/tmp/immich-sync.lock"
PHOTOS_DIR="/Volumes/PhotosSSD/Photos Library.photoslibrary/originals"
STAMP="/tmp/immich-last-sync"
MANIFEST="$HOME/.immich-sync-manifest.txt"
NODE="/opt/homebrew/bin/node"
IMMICH="/opt/homebrew/bin/immich"
[ -f "$HOME/.config/micloud/config.env" ] && { set -a; . "$HOME/.config/micloud/config.env"; set +a; }
LOKI_URL="${MICLOUD_LOKI_URL:-http://LOKI_HOST:3100/loki/api/v1/push}"
export PATH="/opt/homebrew/bin:$PATH"

# Push a structured heartbeat line to Loki.
# Usage: loki_push <event> [extra_kvs]
# event must be one of: started|idle|uploaded|failed|locked|dryrun
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
  payload="{\"streams\":[{\"stream\":{\"job\":\"immich_sync\",\"host\":\"mac-studio\",\"event\":\"${event}\"},\"values\":[[\"${ns_ts}\",\"${line}\"]]}]}"
  curl --max-time 5 -s -X POST "$LOKI_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" -o /dev/null 2>&1 || true
}

# Returns total asset count from Immich API, or empty string on failure.
immich_asset_count() {
    local cred_file="$HOME/.config/immich/auth.yml"
    [ -f "$cred_file" ] || { echo ""; return 1; }
    local url key
    url=$(awk '/^url:/ {sub(/^url:[[:space:]]*/,""); print; exit}' "$cred_file" | tr -d '"')
    key=$(awk '/^key:/ {sub(/^key:[[:space:]]*/,""); print; exit}' "$cred_file" | tr -d '"')
    [ -z "$url" ] || [ -z "$key" ] && { echo ""; return 1; }
    # auth.yml url already includes /api; endpoint is /server/statistics
    /usr/bin/curl -sf --max-time 10 -H "x-api-key: $key" "$url/server/statistics" 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("photos",0)+d.get("videos",0))' \
        2>/dev/null || echo ""
}

# Sanity gate: refuse to proceed if CURRENT looks impossibly small vs MANIFEST.
# Returns 0 if safe to proceed, 1 if anomalous.
sanity_gate() {
    local current_count=$1
    local manifest_count=$2
    # If manifest has fewer than 1000 entries we're not yet established — skip the gate.
    if [ "$manifest_count" -lt 1000 ]; then
        return 0
    fi
    local min_required=$((manifest_count * 90 / 100))
    if [ "$current_count" -lt "$min_required" ]; then
        return 1
    fi
    return 0
}

# Prevent overlapping runs
if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Sync already running (PID $pid), skipping" >> "$LOG"
        loki_push locked
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

# Failure trap — fires on any non-zero exit after lock acquisition.
# STAGE is updated at each major section so the failed event is useful.
# _LOKI_PUSHED=1 suppresses the generic failed push when a specific one was already sent.
STAGE="init"
_LOKI_PUSHED=0
CURRENT=""
CURRENT_PATHS=""
MANIFEST_PATHS=""
MANIFEST_TRIPLES=""
NEW_TRIPLES=""
ADDED=""
DELETED=""
CHANGED=""
TO_UPLOAD=""
NEW_MANIFEST=""
UPLOAD_TMPDIR=""
trap '
  _ec=$?
  rm -f "$CURRENT" "$CURRENT_PATHS" "$MANIFEST_PATHS" "$MANIFEST_TRIPLES" "$NEW_TRIPLES" "$ADDED" "$DELETED" "$CHANGED" "$TO_UPLOAD" "$NEW_MANIFEST" 2>/dev/null
  [ -n "$UPLOAD_TMPDIR" ] && rm -rf "$UPLOAD_TMPDIR" 2>/dev/null
  rm -f "$LOCKFILE"
  if [ "$_ec" -ne 0 ] && [ "$_LOKI_PUSHED" != "1" ]; then
    loki_push failed "exit=$_ec stage=$STAGE"
  fi
' EXIT

loki_push started

# Check Photos Library is mounted
STAGE="mount-check"
if [ ! -d "$PHOTOS_DIR" ]; then
    MSG="ERROR: Photos Library not found at $PHOTOS_DIR"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $MSG" >> "$LOG"
    exit 1
fi

# Build CURRENT as triples: path|size|mtime
STAGE="find"
touch "$MANIFEST"
CURRENT=$(mktemp -t immich-current.XXXXXX)

# Retry up to 3 times if find returns suspiciously few files
# (handles transient Photos.app locks during hourly library maintenance)
for attempt in 1 2 3 4; do
    find "$PHOTOS_DIR" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
        s=$(stat -f '%z|%m' "$f" 2>/dev/null) && printf "%s|%s\n" "$f" "$s"
    done | LC_ALL=C sort > "$CURRENT"

    CURRENT_COUNT=$(wc -l < "$CURRENT" | tr -d ' ')
    MANIFEST_COUNT=$(wc -l < "$MANIFEST" 2>/dev/null | tr -d ' ' || echo 0)

    # Bootstrap (manifest tiny) or count looks reasonable: proceed
    if [ "$MANIFEST_COUNT" -lt 1000 ] || [ "$CURRENT_COUNT" -ge "$((MANIFEST_COUNT * 90 / 100))" ]; then
        if [ "$attempt" -gt 1 ]; then
            loki_push retry_ok "Retry succeeded: found $CURRENT_COUNT files on attempt $attempt"
        fi
        break
    fi

    # Anomalously low — retry if attempts remain
    if [ "$attempt" -lt 4 ]; then
        loki_push retrying "find returned $CURRENT_COUNT files (need >=$((MANIFEST_COUNT * 90 / 100))) — retrying in 30s (attempt $attempt/3)"
        sleep 30
    fi
done

# Final sanity check after retries
if ! sanity_gate "$CURRENT_COUNT" "$MANIFEST_COUNT"; then
    _LOKI_PUSHED=1
    loki_push failed "Sanity gate tripped after 3 retries: found $CURRENT_COUNT files vs expected at least $((MANIFEST_COUNT * 90 / 100)) (manifest=$MANIFEST_COUNT). Filesystem unavailable? Aborting. stage=sanity exit=2 found=$CURRENT_COUNT manifest=$MANIFEST_COUNT"
    exit 2
fi

# Path-only views for set ops
CURRENT_PATHS=$(mktemp -t immich-curpaths.XXXXXX)
MANIFEST_PATHS=$(mktemp -t immich-mpaths.XXXXXX)
awk -F'|' '{print $1}' "$CURRENT" | LC_ALL=C sort -u > "$CURRENT_PATHS"
# Works for both path-only manifest lines and triple-format lines
awk -F'|' '{print $1}' "$MANIFEST" | LC_ALL=C sort -u > "$MANIFEST_PATHS"

# ADDED: in CURRENT but not in MANIFEST (by path)
ADDED=$(mktemp -t immich-added.XXXXXX)
LC_ALL=C comm -23 "$CURRENT_PATHS" "$MANIFEST_PATHS" > "$ADDED"
A_COUNT=$(wc -l < "$ADDED" | tr -d ' ')

# DELETED: paths in MANIFEST but not in CURRENT
DELETED=$(mktemp -t immich-deleted.XXXXXX)
LC_ALL=C comm -13 "$CURRENT_PATHS" "$MANIFEST_PATHS" > "$DELETED"
D_COUNT=$(wc -l < "$DELETED" | tr -d ' ')

# CHANGED: triples in CURRENT that don't match a triple in MANIFEST, where the path IS in MANIFEST.
# Path-only manifest entries have no triple to compare — they never yield CHANGED.
# Guard: skip entirely when manifest has no triples (empty MANIFEST_TRIPLES), otherwise
# comm -23 CURRENT empty-file would mark every current file as changed.
MANIFEST_TRIPLES=$(mktemp -t immich-manifestt.XXXXXX)
grep '|' "$MANIFEST" | LC_ALL=C sort > "$MANIFEST_TRIPLES" 2>/dev/null || true
NEW_TRIPLES=$(mktemp -t immich-newtriples.XXXXXX)
CHANGED=$(mktemp -t immich-changed.XXXXXX)
C_COUNT=0
if [ -s "$MANIFEST_TRIPLES" ]; then
    LC_ALL=C comm -23 "$CURRENT" "$MANIFEST_TRIPLES" > "$NEW_TRIPLES"
    awk -F'|' '{print $1}' "$NEW_TRIPLES" | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$MANIFEST_PATHS" > "$CHANGED"
    C_COUNT=$(wc -l < "$CHANGED" | tr -d ' ')
fi

# Combined upload list: ADDED ∪ CHANGED
TO_UPLOAD=$(mktemp -t immich-toupload.XXXXXX)
cat "$ADDED" "$CHANGED" | LC_ALL=C sort -u > "$TO_UPLOAD"
TOTAL_TO_UPLOAD=$(wc -l < "$TO_UPLOAD" | tr -d ' ')

# DRY_RUN: report what would happen, don't upload, don't write manifest
# Checked before idle so DRY_RUN=1 always emits dryrun (even when nothing changed)
if [ "${DRY_RUN:-0}" = "1" ]; then
    loki_push dryrun "DRY RUN: would upload $A_COUNT added + $C_COUNT changed; would record $D_COUNT deleted (took ${SECONDS}s) added=$A_COUNT changed=$C_COUNT deleted=$D_COUNT"
    exit 0
fi

if [ "$TOTAL_TO_UPLOAD" -eq 0 ] && [ "$D_COUNT" -eq 0 ]; then
    loki_push idle "No changes detected (took ${SECONDS}s) added=0 changed=0 deleted=0"
    exit 0
fi

BEFORE_COUNT=$(immich_asset_count)

# Build symlink tmpdir for upload
STAGE="upload"
UPLOAD_TMPDIR=$(mktemp -d -t immich-upload.XXXXXX)

while IFS= read -r f; do
    [ -n "$f" ] && ln -s "$f" "$UPLOAD_TMPDIR/$(basename "$f")" 2>/dev/null || true
done < "$TO_UPLOAD"

find "$UPLOAD_TMPDIR" -maxdepth 1 -type l -print0 | xargs -0 $NODE $IMMICH upload >> "$LOG" 2>&1
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    exit "$STATUS"
fi

AFTER_COUNT=$(immich_asset_count)
if [ -n "$BEFORE_COUNT" ] && [ -n "$AFTER_COUNT" ]; then
    DELTA=$((AFTER_COUNT - BEFORE_COUNT))
    if [ "$AFTER_COUNT" -ge "$BEFORE_COUNT" ]; then
        loki_push immich_verified "before=$BEFORE_COUNT after=$AFTER_COUNT delta=$DELTA expected=$TOTAL_TO_UPLOAD"
    else
        loki_push immich_drift "before=$BEFORE_COUNT after=$AFTER_COUNT delta=$DELTA expected=$TOTAL_TO_UPLOAD (Immich asset count went DOWN — investigate)"
    fi
else
    loki_push immich_check_skipped "Immich API unavailable; verification skipped"
fi

STAGE="manifest-write"
# Atomic manifest write with rotation: write to tmp, backup current, then mv
NEW_MANIFEST=$(mktemp -t immich-newmanifest.XXXXXX)
cp "$CURRENT" "$NEW_MANIFEST"
[ -f "$MANIFEST" ] && cp "$MANIFEST" "$MANIFEST.last"
mv "$NEW_MANIFEST" "$MANIFEST"

# Build samples for log line
SAMPLE_LIST=$(cat "$ADDED" "$CHANGED" "$DELETED" 2>/dev/null | head -3 | xargs -I{} basename "{}" 2>/dev/null | tr '\n' ',' | sed 's/,$//; s/,/, /g')
TOTAL=$((A_COUNT + C_COUNT + D_COUNT))
MORE=$((TOTAL - 3))
if [ "$MORE" -lt 0 ]; then MORE=0; fi
SAMPLE_TEXT=""
if [ -n "$SAMPLE_LIST" ]; then
    SAMPLE_TEXT=" — files: $SAMPLE_LIST"
    [ "$MORE" -gt 0 ] && SAMPLE_TEXT="$SAMPLE_TEXT +$MORE more"
fi

loki_push uploaded "Sync complete: $A_COUNT added, $C_COUNT changed, $D_COUNT deleted (${SECONDS}s)$SAMPLE_TEXT added=$A_COUNT changed=$C_COUNT deleted=$D_COUNT"

touch "$STAMP"

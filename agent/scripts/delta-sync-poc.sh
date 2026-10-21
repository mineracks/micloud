#!/bin/bash
# delta-sync-poc.sh — thin-cache ONE-WAY sync of an iCloud Drive subtree -> Nextcloud.
# Proves: metadata-only delta scan (no materialization) -> materialize delta on demand
#         -> forward to Nextcloud -> evict (keep local footprint ~0). Soft-delete only.
set -uo pipefail
SRC="$HOME/Library/Mobile Documents/com~apple~CloudDocs/_deltasync-poc"
DST="nextcloud:_deltasync-poc"
STATE="$HOME/deltasync-poc/manifest.tsv"
FP="/usr/bin/python3 $HOME/deltasync-poc/icloud-fp.py"
RCLONE=/opt/homebrew/bin/rclone
NEW=$(mktemp); touch "$STATE"
# 1. metadata-only scan: relpath \t mtime \t size  (stat does NOT materialize dataless files)
cd "$SRC" || exit 1
while IFS= read -r -d '' f; do printf '%s\t%s\t%s\n' "$f" "$(stat -f %m "$f")" "$(stat -f %z "$f")"; done \
  < <(find . -type f ! -name '.*' -print0) | sort > "$NEW"
# 2. delta
addmod=$(comm -23 "$NEW" <(sort "$STATE") | cut -f1 | sort -u)
deleted=$(comm -13 <(cut -f1 "$NEW"|sort -u) <(cut -f1 "$STATE"|sort -u))
echo "delta: added/modified=$(printf '%s' "$addmod"|grep -c .)  deleted=$(printf '%s' "$deleted"|grep -c .)"
# 3. materialize -> forward -> evict
while IFS= read -r rel; do [ -z "$rel" ] && continue; f="$SRC/${rel#./}"
  $FP download "$f" 120 >/dev/null 2>&1 || { echo "  FAIL materialize $rel"; continue; }
  $RCLONE copyto "$f" "$DST/${rel#./}" >/dev/null 2>&1 || { echo "  FAIL forward $rel"; continue; }
  $FP evict "$f" >/dev/null 2>&1
  echo "  synced+evicted: $rel"
done <<< "$addmod"
# 4. soft-delete (one-way: never touch iCloud; NC copy -> dated trash)
while IFS= read -r rel; do [ -z "$rel" ] && continue
  $RCLONE moveto "$DST/${rel#./}" "nextcloud:.trash/deltasync/$(date +%F)/${rel#./}" >/dev/null 2>&1
  echo "  soft-deleted: $rel"
done <<< "$deleted"
mv "$NEW" "$STATE"   # commit checkpoint AFTER forwarding
echo "checkpoint committed ($(wc -l < "$STATE" | tr -d ' ') files tracked); local cache thin"

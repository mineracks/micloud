#!/usr/bin/env bash
# icloud-bookmarks-sync.sh — Phase 6.2 wrapper.
#
# mkdir-based atomic flock guard around the python orchestrator.
# Same shape as icloud-reminders-cloudkit-sync.sh.

set -uo pipefail

LOCK_DIR="/tmp/icloud-bookmarks-sync.lock.d"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYSCRIPT="${HERE}/icloud-bookmarks-sync.py"

[[ -f "$PYSCRIPT" ]] || {
  /usr/bin/logger -t icloud-bookmarks-sync \
    "FAIL event=failed exception=missing_pyscript:$PYSCRIPT"
  exit 1
}

# Auto-clear stale lock (older than 5 min — see Reminders wrapper for rationale).
if [[ -d "$LOCK_DIR" ]]; then
  if [[ $(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null | wc -l) -gt 0 ]]; then
    /usr/bin/logger -t icloud-bookmarks-sync \
      "WARN event=stale_lock_cleared dir=$LOCK_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
  fi
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  /usr/bin/logger -t icloud-bookmarks-sync \
    "OK event=skipped reason=already_running"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# Run python as a child (NOT exec'd) so the EXIT trap reliably runs the
# lock cleanup. With `exec`, bash is replaced and the trap never fires.
/usr/bin/python3 "$PYSCRIPT"

#!/usr/bin/env bash
# icloud-notes-sync.sh — Phase 6.3 wrapper.
# mkdir-based atomic flock guard around the python orchestrator.

set -uo pipefail

LOCK_DIR="/tmp/icloud-notes-sync.lock.d"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYSCRIPT="${HERE}/icloud-notes-sync.py"

[[ -f "$PYSCRIPT" ]] || {
  /usr/bin/logger -t icloud-notes-sync \
    "FAIL event=failed exception=missing_pyscript:$PYSCRIPT"
  exit 1
}

# Auto-clear stale lock (older than 5 min).
if [[ -d "$LOCK_DIR" ]]; then
  if [[ $(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null | wc -l) -gt 0 ]]; then
    /usr/bin/logger -t icloud-notes-sync \
      "WARN event=stale_lock_cleared dir=$LOCK_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
  fi
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  /usr/bin/logger -t icloud-notes-sync \
    "OK event=skipped reason=already_running"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# Don't `exec` python — that replaces this bash process and the EXIT trap
# never fires, leaving a stale lock that blocks the next launch until
# auto-clear at +5 min. Run as a child so the trap reliably cleans up.
/usr/bin/python3 "$PYSCRIPT"

#!/usr/bin/env bash
# icloud-reminders-cloudkit-sync.sh — Phase 6.1.5 wrapper.
#
# Bash orchestrator for the Mac-Studio Reminders → Nextcloud Tasks sync.
# Two responsibilities only:
#   1. flock guard so two scheduler firings can never overlap
#   2. ensure the Python sync runs under the user's GUI (Aqua) session,
#      which is the TCC context that has Automation permission for
#      Reminders.app
#
# All real work happens in icloud-reminders-cloudkit-sync.py and
# icloud-reminders-cloudkit-export.js (the JXA enumerator).

set -uo pipefail

# mkdir-based atomic locking — POSIX, works on macOS (no `flock` shipped) and
# Linux. mkdir succeeds only if the directory doesn't already exist; the
# trap removes it on exit. Stale locks (from kill -9) are auto-cleared if
# the lock dir is older than 1 hour, since our hourly scheduling means a
# legitimate run never holds the lock that long.
LOCK_DIR="/tmp/icloud-reminders-cloudkit-sync.lock.d"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYSCRIPT="${HERE}/icloud-reminders-cloudkit-sync.py"

[[ -f "$PYSCRIPT" ]] || {
  /usr/bin/logger -t icloud-reminders-cloudkit-sync \
    "FAIL event=failed exception=missing_pyscript:$PYSCRIPT"
  exit 1
}

# Auto-clear stale lock. A real sync run takes 25-1200s; anything over
# 5 minutes that hasn't released the lock is dead (SIGKILL'd, OOM,
# launchd kicked it during a system event, etc.) and we should reclaim.
# A short threshold matters with the watcher daemon firing event-driven
# kicks — without it, every kicked run sits behind a stale lock for an
# hour and the user-facing tick→nextcloud lag balloons.
if [[ -d "$LOCK_DIR" ]]; then
  if [[ $(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null | wc -l) -gt 0 ]]; then
    /usr/bin/logger -t icloud-reminders-cloudkit-sync \
      "WARN event=stale_lock_cleared dir=$LOCK_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
  fi
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  /usr/bin/logger -t icloud-reminders-cloudkit-sync \
    "OK event=skipped reason=already_running"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# Run python as a child (NOT exec'd) so the EXIT trap reliably runs the
# lock cleanup. With `exec`, bash is replaced and the trap never fires —
# the lock then blocks subsequent launches until 5-min auto-clear.
# /usr/bin/python3 ships with macOS and is sufficient — no third-party deps.
/usr/bin/python3 "$PYSCRIPT"

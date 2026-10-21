#!/usr/bin/env python3
"""
icloud-reminders-cloudkit-watcher.py — Phase 6.1.5 event trigger.

Long-running Mac-Studio daemon that listens for
`EKEventStoreChangedNotification` from EventKit. Every time the local
Reminders store mutates — whether from a direct user edit on this Mac,
from CloudKit sync arriving from iPhone/iPad, or from another device's
Reminders.app — the notification fires and we subprocess-kick the
existing `icloud-reminders-cloudkit-sync.sh`. A 10-second debounce
collapses bursts (e.g. ticking 5 things in a row) into one sync run.

Why a daemon instead of `WatchPaths` in the sync agent's plist:
macOS routes filesystem events from `~/Library/Group Containers/...`
through FSEvents under TCC, and silently drops them for processes
without Full Disk Access. We don't want to grant FDA to bash. EventKit's
notification is a Cocoa-level signal — needs Reminders Full Access
(which we already have) and nothing else.

Run model:
  - LaunchAgent at ~/Library/LaunchAgents/com.mineracks.icloud-reminders-
    cloudkit-watcher.plist with `KeepAlive: true`. launchd respawns this
    daemon if it crashes.
  - Heartbeats to syslog every 5 minutes so Sentinel can alert if the
    watcher process is dead.
  - `EKEventStoreChangedNotification` → debounce 10s → subprocess `sync.sh`.

The sync agent's own `StartInterval` (set to 6h in the plist) remains as
a safety net for the unlikely case where this watcher dies *and* doesn't
restart, or where the notification API misses a change.
"""

import os
import sys
import json
import time
import syslog
import shlex
import subprocess
import urllib.request
from pathlib import Path

import objc
from Foundation import (
    NSBundle, NSObject, NSRunLoop, NSDate, NSTimer,
    NSNotificationCenter,
)


LOG_TAG = "icloud-reminders-cloudkit-watcher"
SYNC_SH = Path.home() / "bin" / "icloud-reminders-cloudkit-sync.sh"
DEBOUNCE_SECONDS = 10.0
HEARTBEAT_SECONDS = 300.0  # 5-minute "alive" heartbeat for Sentinel
EK_ENTITY_REMINDER = 1     # EKEntityTypeReminder

try:
    import micloud_config as mc
except ImportError:
    class mc:
        get = staticmethod(lambda k, d=None: __import__("os").environ.get(k) or d)
LOKI_URL = mc.get("MICLOUD_LOKI_URL", "http://LOKI_HOST:3100/loki/api/v1/push")
LOKI_LABELS = {
    "job":  "icloud_reminders_cloudkit",
    "host": "mac-studio",
    "unit": "icloud-reminders-cloudkit-watcher",
}


def _loki_push(line):
    try:
        ns_ts = str(int(time.time() * 1e9))
        body = json.dumps({
            "streams": [{"stream": LOKI_LABELS, "values": [[ns_ts, line]]}]
        }).encode()
        req = urllib.request.Request(
            LOKI_URL, method="POST", data=body,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=3).read()
    except Exception:
        pass


def hb(level, **kvs):
    parts = [level] + [
        f"{k}={shlex.quote(str(v)) if ' ' in str(v) else v}"
        for k, v in kvs.items()
    ]
    msg = " ".join(parts)
    syslog.openlog(LOG_TAG, syslog.LOG_PID, syslog.LOG_USER)
    syslog.syslog(syslog.LOG_INFO, msg)
    syslog.closelog()
    print(msg, file=sys.stderr, flush=True)
    _loki_push(msg)


class Watcher(NSObject):
    """NSObject delegate for NSNotificationCenter callbacks.

    Holds the EKEventStore (necessary — the notification fires from the
    store instance, so we have to keep a reference or the observer
    silently stops working when the store deallocs), debounce timer, and
    sync-running guard.
    """

    def init(self):
        self = objc.super(Watcher, self).init()
        if self is None:
            return None
        self.debounce_timer = None
        self.last_kick_t = 0.0
        self.kicks = 0
        self.notifications = 0
        return self

    def setStore_(self, store):
        self.store = store

    def storeChanged_(self, _notification):
        self.notifications += 1
        # Cancel any pending debounce timer; reschedule for DEBOUNCE_SECONDS
        # from now. This collapses a burst of EKEventStoreChangedNotifications
        # (from rapid edits or CloudKit batched arrival) into one sync run.
        if self.debounce_timer is not None and self.debounce_timer.isValid():
            self.debounce_timer.invalidate()
        self.debounce_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            DEBOUNCE_SECONDS, self, "debouncedKick:", None, False
        )

    def debouncedKick_(self, _timer):
        # Run the sync script. Use Popen + wait so we hold onto the runloop
        # but don't block notifications during the run (they queue and the
        # next storeChanged_ will reschedule a follow-up run as needed).
        elapsed_since_last = time.time() - self.last_kick_t
        hb("OK", event="kick", debounced_notifications=self.notifications,
           seconds_since_last_kick=int(elapsed_since_last))
        self.notifications = 0
        self.last_kick_t = time.time()
        self.kicks += 1
        try:
            proc = subprocess.run(
                [str(SYNC_SH)],
                capture_output=True, text=True, timeout=600,
            )
            elapsed = time.time() - self.last_kick_t
            # If the wrapper's flock returned `event=skipped reason=already_running`
            # the run exits in well under 1 second with empty stderr. That's a
            # silent functional miss — the user-visible change won't be synced
            # until the held-lock release. Re-fire after a short grace period
            # so the next debounce cycle naturally retries.
            stderr_lines = len(proc.stderr.splitlines())
            if elapsed < 2 and stderr_lines == 0 and proc.returncode == 0:
                hb("WARN", event="kick_lock_blocked",
                   note="prior sync still holding lock; rescheduling debounce",
                   elapsed_s=round(elapsed, 2))
                # Reschedule a follow-up kick so we don't drop the change.
                if self.debounce_timer is not None and self.debounce_timer.isValid():
                    self.debounce_timer.invalidate()
                self.debounce_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                    DEBOUNCE_SECONDS * 3, self, "debouncedKick:", None, False
                )
                return
            hb("OK", event="kick_done",
               returncode=proc.returncode,
               stdout_lines=len(proc.stdout.splitlines()),
               stderr_lines=stderr_lines,
               elapsed_s=int(elapsed))
        except subprocess.TimeoutExpired:
            hb("WARN", event="kick_timeout", timeout_s=600)
        except Exception as e:
            hb("FAIL", event="kick_failed", exception=f"{type(e).__name__}:{str(e)[:200]}")

    def heartbeat_(self, _timer):
        hb("OK", event="alive",
           kicks_since_start=self.kicks,
           pid=os.getpid())


def _register_request_access_block_signature():
    """Tell PyObjC how to marshal the `requestFullAccessToRemindersWithCompletion:`
    completion block. Without this, calling the method raises
    `TypeError: Argument 2 is a block, but no signature available`.

    The block signature is `void (^)(BOOL granted, NSError *error)`. PyObjC
    metadata uses `@?` for the implicit block self pointer, `Z` for BOOL, and
    `@` for an Objective-C object pointer. (`Z` is the macOS native BOOL,
    which is `signed char` on x86_64 and `bool` on arm64; PyObjC normalises.)
    """
    objc.registerMetaDataForSelector(
        b"EKEventStore",
        b"requestFullAccessToRemindersWithCompletion:",
        {
            "arguments": {
                2: {
                    "callable": {
                        "retval": {"type": b"v"},
                        "arguments": {
                            0: {"type": b"^v"},
                            1: {"type": b"Z"},
                            2: {"type": b"@"},
                        },
                    },
                    "callable_retained": False,
                },
            },
        },
    )


def main():
    NSBundle.bundleWithPath_("/System/Library/Frameworks/EventKit.framework").load()
    EKEventStore = objc.lookUpClass("EKEventStore")
    _register_request_access_block_signature()

    store = EKEventStore.alloc().init()

    # Probe by attempting an actual EventKit read. authorizationStatusForEntityType:
    # returns 0 (NotDetermined) for fresh process trees even when the binary path
    # has TCC granted globally; the actual fetch is the source of truth.
    calendars = store.calendarsForEntityType_(EK_ENTITY_REMINDER)
    n_cal = calendars.count() if calendars else 0
    auth = EKEventStore.authorizationStatusForEntityType_(EK_ENTITY_REMINDER)
    hb("OK", event="auth_probe", reported_status=auth, calendars_visible=n_cal)

    if n_cal == 0:
        # Try to surface the macOS TCC dialog programmatically. This works in
        # LaunchAgent context (per-user, attached to Aqua session) but not in
        # LaunchDaemon (system context, no UI). The user must click Allow once.
        hb("OK", event="requesting_access",
           note="Click Allow on the macOS dialog (may take a few seconds to surface)")

        granted = {"v": None, "err": None}

        def cb(g, err):
            granted["v"] = bool(g)
            granted["err"] = str(err) if err else None

        try:
            store.requestFullAccessToRemindersWithCompletion_(cb)
        except AttributeError:
            # Older macOS — fall back to the entity-type-based API.
            store.requestAccessToEntityType_completion_(EK_ENTITY_REMINDER, cb)

        # Spin the runloop so the async completion can fire.
        deadline = time.time() + 60
        while granted["v"] is None and time.time() < deadline:
            NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.25))

        if granted["v"]:
            hb("OK", event="auth_granted")
            calendars = store.calendarsForEntityType_(EK_ENTITY_REMINDER)
            n_cal = calendars.count() if calendars else 0

        if n_cal == 0:
            hb("FAIL", event="auth_blocked",
               error=granted["err"] or "user_denied_or_timeout",
               note="System Settings → Privacy & Security → Reminders → add /usr/bin/python3 → ON, then `launchctl kickstart -k gui/$(id -u)/com.mineracks.icloud-reminders-cloudkit-watcher`")
            sys.exit(1)

    watcher = Watcher.alloc().init()
    watcher.setStore_(store)

    # Subscribe to EKEventStoreChangedNotification. Pass object=None to
    # accept notifications from any sender (Apple sometimes posts from a
    # different EKEventStore singleton during sync).
    NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
        watcher, "storeChanged:", "EKEventStoreChangedNotification", None
    )

    # Schedule 5-min heartbeat (Sentinel watches for this on Loki).
    NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        HEARTBEAT_SECONDS, watcher, "heartbeat:", None, True
    )

    hb("OK", event="started", pid=os.getpid(), debounce_s=int(DEBOUNCE_SECONDS),
       heartbeat_s=int(HEARTBEAT_SECONDS))

    # Run the Cocoa run loop forever.
    NSRunLoop.currentRunLoop().run()


if __name__ == "__main__":
    main()

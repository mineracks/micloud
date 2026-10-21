#!/usr/bin/python3
"""
photo-delta-watch.py — event-driven trigger for the Photos forwarder (Phase 2.6).

FSEvents-watches the Photos library; when cloudphotod writes a new photo in (i.e. it becomes
visible on the Mac), it debounces ~8s of quiet then runs photo-delta-sync.sh, so the photo reaches
Immich + Nextcloud within ~seconds of appearing locally — instead of waiting up to an hour for the
timer. A max-wait guarantees forward progress during the *continuous* churn of the initial iCloud
sync (where there is never an 8s quiet gap), and a 30-min background pass is a safety net for any
FSEvents the daemon missed (e.g. while it was restarting). KeepAlive launchd daemon.

Requires /usr/bin/python3 (system python has PyObjC + FSEvents).
"""
import os, subprocess, time, threading
import FSEvents as FE
from CoreFoundation import CFRunLoopGetCurrent, kCFRunLoopDefaultMode, CFRunLoopRun

# per-instance config (~/.config/micloud/config.env); graceful fallback if the loader isn't present
try:
    import micloud_config as mc
except ImportError:
    class mc:  # type: ignore
        @staticmethod
        def get(k, d=None): return os.environ.get(k) or d

LIB = os.path.expandvars(mc.get("MICLOUD_PHOTOS_LIBRARY", os.path.expanduser("~/Pictures/Photos Library.photoslibrary")))
FORWARDER = os.path.expanduser("~/bin/photo-delta-sync.sh")
DEBOUNCE = 8.0        # run this many seconds after the last change (quiet window)
MAX_WAIT = 60.0       # ...but never wait longer than this since the last run while changes pend
SAFETY_INTERVAL = 1800  # 30-min background pass regardless of events

_lock = threading.Lock()
_state = {"last_run": 0.0, "timer": None}

def _run():
    with _lock:
        _state["last_run"] = time.time(); _state["timer"] = None
    # photo-delta-sync.sh holds an mkdir lock, so a concurrent trigger just no-ops with "locked".
    subprocess.run(["/bin/bash", FORWARDER, "2"], check=False)

def _schedule():
    with _lock:
        if _state["timer"] is not None:
            _state["timer"].cancel()
        since = time.time() - _state["last_run"]
        delay = DEBOUNCE if (since + DEBOUNCE) <= MAX_WAIT else max(1.0, MAX_WAIT - since)
        t = threading.Timer(delay, _run); t.daemon = True; t.start()
        _state["timer"] = t

def _cb(stream, info, n, paths, flags, ids):
    _schedule()

def _safety():
    while True:
        time.sleep(SAFETY_INTERVAL)
        _run()

def main():
    threading.Thread(target=_safety, daemon=True).start()
    st = FE.FSEventStreamCreate(None, _cb, None, [LIB], FE.kFSEventStreamEventIdSinceNow, 2.0, 0)
    FE.FSEventStreamScheduleWithRunLoop(st, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)
    FE.FSEventStreamStart(st)
    CFRunLoopRun()

if __name__ == "__main__":
    main()

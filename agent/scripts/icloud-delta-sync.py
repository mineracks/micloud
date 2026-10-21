#!/usr/bin/python3
"""
icloud-delta-sync.py — thin-cache, ONE-WAY delta sync of an iCloud Drive folder to Nextcloud.
icloud-sovereign-backup epic, Phase 2.6.

Change source = **FSEvents** (changed paths since a persisted event-ID). This NEVER lists the
tree, so it cannot wedge on a dataless directory listing — the FileProvider deadlock that hangs
`os.walk`/rclone (`readdir` on an evicted dir never returns). Each changed path is stat'd
individually (fast on dataless files) then materialize -> forward -> evict. Deletes -> soft-delete
to Nextcloud .trash (one-way; iCloud is never written).

Modes:
  (default)    replay FSEvents since the stored checkpoint; process each changed path; advance it.
  --reconcile  safety-net: a robust local scan (child process + SIGKILL timeout, so a wedged
               dataless-dir readdir can't hang the job) cross-checked against the full Nextcloud
               listing; forward anything Nextcloud is missing. Run weekly / after a dropped-events
               warning.
  --scan-only  internal: emit "relpath\tmtime\tsize" for the tree (the --reconcile child process).

Bootstrap (empty manifest): set the checkpoint to the current FSEvents id and return — NO tree
walk. The Phase-2 corpus already lives in Nextcloud and FSEvents carries every change from here on.

Primitives (verified 2026-07-04): brctl download/evict are gone and fileproviderctl is
diagnostic-only, but NSFileManager evictUbiquitousItemAtURL:/startDownloadingUbiquitousItemAtURL:
and the FSEvents framework all work via PyObjC on system /usr/bin/python3 (Homebrew python3 does not).
"""
import argparse, os, sqlite3, subprocess, time, fcntl, json, sys, threading, urllib.request
from Foundation import NSFileManager, NSURL
import FSEvents as FE
from CoreFoundation import (CFRunLoopGetCurrent, kCFRunLoopDefaultMode,
                            CFRunLoopRunInMode, CFRunLoopStop, CFRunLoopRun)

# Per-instance config (~/.config/micloud/config.env). Falls back to env-var-or-default if the
# shared loader isn't deployed alongside, so the daemon still runs standalone.
try:
    import micloud_config as mc
except ImportError:
    class mc:  # type: ignore
        @staticmethod
        def get(k, d=None): return os.environ.get(k) or d

def parse_args():
    _nc = mc.get("MICLOUD_NC_REMOTE", "nextcloud")
    p = argparse.ArgumentParser()
    p.add_argument("--src", default=os.path.expandvars(mc.get("MICLOUD_DOCUMENTS_SRC", os.path.expanduser("~/Documents"))))
    p.add_argument("--dst", default="%s:%s" % (_nc, mc.get("MICLOUD_NC_DOCUMENTS", "Documents")))
    p.add_argument("--trash", default=mc.get("MICLOUD_NC_TRASH", "%s:.trash/deltasync" % _nc))
    p.add_argument("--db", default=os.path.expanduser("~/Library/Application Support/icloud-delta-sync/documents.db"))
    p.add_argument("--rclone", default=mc.get("MICLOUD_RCLONE", "/opt/homebrew/bin/rclone"))
    p.add_argument("--loki", default=mc.get("MICLOUD_LOKI_URL", "http://LOKI_HOST:3100/loki/api/v1/push"))
    p.add_argument("--label", default="delta-documents")
    p.add_argument("--no-evict", dest="evict", action="store_false")
    p.add_argument("--watch", action="store_true",
                   help="run as an event-driven daemon: react to FSEvents within ~2s (the ideal). "
                        "Without it, a single one-shot replay-since-checkpoint runs (timer/mop-up mode).")
    p.add_argument("--reconcile", action="store_true")
    p.add_argument("--scan-only", action="store_true")
    p.add_argument("--materialize-timeout", type=int, default=300)
    p.add_argument("--drain-timeout", type=int, default=45, help="max seconds to drain FSEvents history")
    p.add_argument("--scan-timeout", type=int, default=240, help="SIGKILL the reconcile child scan after this")
    p.add_argument("--batch-max", type=int, default=1000)
    return p.parse_args()

EXCLUDE_SUFFIXES = (".app", ".photoslibrary", ".xcodeproj", ".xcworkspace", ".dSYM", ".screenflow",
    ".playground", ".xcdatamodel", ".xcdatamodeld", ".pvm", ".pvmp", ".vmwarevm", ".utm",
    ".sparsebundle", ".sparseimage", ".imovielibrary", ".tvlibrary", ".fcpbundle", ".logicx",
    ".band", ".migbundle", ".rcproject")
EXCLUDE_NAMES = {".DS_Store", ".localized", ".htaccess"}

# ---------------- iCloud primitives (PyObjC) ----------------
_FM = NSFileManager.defaultManager()
KEY_STATUS = "NSURLUbiquitousItemDownloadingStatusKey"
KEY_UP = "NSURLUbiquitousItemIsUploadedKey"
def _url(p): return NSURL.fileURLWithPath_(p)
def _status(p):
    v, _ = _url(p).resourceValuesForKeys_error_([KEY_STATUS, KEY_UP], None)
    if v is None: return (None, None)
    return (str(v.objectForKey_(KEY_STATUS)), bool(v.objectForKey_(KEY_UP)))
def materialize(p, timeout):
    st, _ = _status(p)
    if st and "Current" in st: return True
    ok, _ = _FM.startDownloadingUbiquitousItemAtURL_error_(_url(p), None)
    if not ok: return False
    t0 = time.time()
    while time.time() - t0 < timeout:
        st, _ = _status(p)
        if st and "Current" in st: return True
        time.sleep(0.5)
    return False
def evict(p):
    _, up = _status(p)
    if not up: return False           # never evict a not-yet-uploaded change
    ok, _ = _FM.evictUbiquitousItemAtURL_error_(_url(p), None)
    return bool(ok)

def excluded(rel):
    for seg in rel.split("/"):
        if seg in EXCLUDE_NAMES or seg.endswith(EXCLUDE_SUFFIXES): return True
    return False

# ---------------- FSEvents change-source ----------------
FL_HISTDONE = 0x10; FL_MUSTSCAN = 0x1; FL_USERDROP = 0x2; FL_KERNDROP = 0x4
def fsevents_delta(src, since_id, drain_timeout):
    """Replay changed paths since `since_id`. Returns (abs_paths_set, must_rescan)."""
    changed = set(); state = {"rescan": False}
    def cb(stream, info, n, paths, flags, ids):
        for p, f in zip(paths, flags):
            if f & FL_HISTDONE:
                CFRunLoopStop(CFRunLoopGetCurrent()); return
            if f & (FL_MUSTSCAN | FL_USERDROP | FL_KERNDROP): state["rescan"] = True
            changed.add(p.decode("utf-8", "replace") if isinstance(p, bytes) else str(p))
    st = FE.FSEventStreamCreate(None, cb, None, [src], int(since_id), 0.2,
                                FE.kFSEventStreamCreateFlagFileEvents)
    if not st:
        return set(), True
    FE.FSEventStreamScheduleWithRunLoop(st, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)
    FE.FSEventStreamStart(st)
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, float(drain_timeout), False)  # stops early on HistoryDone
    FE.FSEventStreamStop(st); FE.FSEventStreamInvalidate(st); FE.FSEventStreamRelease(st)
    return changed, state["rescan"]

def current_event_id(): return FE.FSEventsGetCurrentEventId()

def to_rel(abs_path, src):
    """Map an FSEvents absolute path to a path relative to src, handling the macOS firmlink
    prefix (/System/Volumes/Data/Users == /Users)."""
    for pfx in (src.rstrip("/") + "/", "/System/Volumes/Data" + src.rstrip("/") + "/"):
        if abs_path == pfx.rstrip("/"): return ""      # the src root itself
        if abs_path.startswith(pfx): return abs_path[len(pfx):]
    return None

# ---------------- rclone / loki / db ----------------
def rclone(cfg, *args): return subprocess.run([cfg.rclone, *args], capture_output=True, text=True)
def loki_push(cfg, event, extra=""):
    ns = int(time.time() * 1e9); iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = ("%s %s %s" % (iso, event, extra)).strip()
    payload = {"streams": [{"stream": {"job": "icloud_drive_sync",
               "host": mc.get("MICLOUD_HOST_LABEL", "mac-studio"),
               "event": event, "script": cfg.label}, "values": [[str(ns), line]]}]}
    try:
        req = urllib.request.Request(cfg.loki, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    except Exception:
        pass
def db_open(path):
    os.makedirs(os.path.dirname(path), exist_ok=True); c = sqlite3.connect(path)
    c.execute("CREATE TABLE IF NOT EXISTS files(rel TEXT PRIMARY KEY, mtime INT, size INT, "
              "state TEXT, nc_confirmed_at INT, materialize_fails INT DEFAULT 0, last_error TEXT)")
    c.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
    c.commit(); return c
def get_meta(c, k, d=None):
    r = c.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone(); return r[0] if r else d
def set_meta(c, k, v):
    c.execute("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", (k, str(v))); c.commit()

# ---------------- scan (reconcile safety-net only) ----------------
def scan(src):
    out = {}
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_NAMES and not d.endswith(EXCLUDE_SUFFIXES)]
        for f in files:
            full = os.path.join(root, f); rel = os.path.relpath(full, src)
            if excluded(rel): continue
            try: st = os.lstat(full)
            except OSError: continue
            out[rel] = (int(st.st_mtime), int(st.st_size))
    return out
def robust_scan(cfg):
    """Run scan() in a child process; SIGKILL it if a dataless-dir readdir wedges (SIGKILL DOES
    kill a hung-syscall process, unlike a Python SIGALRM handler). Returns dict or None if wedged."""
    proc = subprocess.Popen(["/usr/bin/python3", os.path.abspath(sys.argv[0]), "--scan-only",
                             "--src", cfg.src], stdout=subprocess.PIPE, text=True)
    try:
        out, _ = proc.communicate(timeout=cfg.scan_timeout)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.communicate(); return None
    cur = {}
    for ln in out.splitlines():
        try: rel, mt, sz = ln.rsplit("\t", 2); cur[rel] = (int(mt), int(sz))
        except ValueError: pass
    return cur

# ---------------- process one changed path ----------------
def process_change(cfg, c, rel, cnt):
    if not rel or excluded(rel): return
    full = os.path.join(cfg.src, rel)
    if os.path.isfile(full) and not os.path.islink(full):
        try: st = os.lstat(full)
        except OSError: return
        mt, sz = int(st.st_mtime), int(st.st_size)
        row = c.execute("SELECT mtime,size,state FROM files WHERE rel=?", (rel,)).fetchone()
        if row and row[2] == "synced" and row[0] == mt and row[1] == sz: return  # unchanged
        if not materialize(full, cfg.materialize_timeout):
            c.execute("INSERT OR REPLACE INTO files(rel,mtime,size,state,materialize_fails,last_error) "
                      "VALUES(?,?,?,'deadletter',COALESCE((SELECT materialize_fails FROM files WHERE rel=?),0)+1,"
                      "'materialize_timeout')", (rel, mt, sz, rel)); c.commit(); cnt["fails"] += 1; return
        r = rclone(cfg, "copyto", full, cfg.dst + "/" + rel)
        if r.returncode != 0:
            c.execute("INSERT OR REPLACE INTO files(rel,mtime,size,state,last_error) VALUES(?,?,?,'pending',?)",
                      (rel, mt, sz, r.stderr[:200])); c.commit(); cnt["fails"] += 1; return
        c.execute("INSERT OR REPLACE INTO files(rel,mtime,size,state,nc_confirmed_at,materialize_fails,last_error) "
                  "VALUES(?,?,?,'synced',?,0,NULL)", (rel, mt, sz, int(time.time()))); c.commit()
        cnt["synced"] += 1; cnt["bytes"] += sz
        if cfg.evict: evict(full)
    elif not os.path.lexists(full):
        # deleted — soft-delete this path plus any manifest files beneath it (it may have been a dir)
        rows = [r[0] for r in c.execute("SELECT rel FROM files WHERE rel=? OR rel LIKE ?", (rel, rel + "/%"))]
        for t in (rows or [rel]):
            rclone(cfg, "moveto", cfg.dst + "/" + t, cfg.trash + "/" + cnt["date"] + "/" + t)
            c.execute("DELETE FROM files WHERE rel=?", (t,)); cnt["deleted"] += 1
        c.commit()

def do_reconcile(cfg, c, cnt):
    cur = robust_scan(cfg)
    if cur is None:
        loki_push(cfg, "scan_stall", "reconcile scan wedged, SIGKILL'd"); return False
    have = rclone(cfg, "lsf", "-R", "--files-only", "--format", "sp", cfg.dst)
    nc = set()
    for ln in have.stdout.splitlines():
        try: sz, pth = ln.split(";", 1); nc.add((pth, int(sz)))
        except ValueError: pass
    now = int(time.time())
    for rel, (mt, sz) in cur.items():
        if (rel, sz) in nc:
            c.execute("INSERT OR IGNORE INTO files(rel,mtime,size,state,nc_confirmed_at) "
                      "VALUES(?,?,?,'synced',?)", (rel, mt, sz, now))
        else:
            process_change(cfg, c, rel, cnt)
    c.commit(); return True

def watch(cfg, c):
    """Event-driven daemon: react to iCloud Drive changes within the FSEvents latency (~2s).
    Processes each changed path in the stream callback (materialize -> forward -> evict / soft-delete),
    advancing the checkpoint to the max processed event-id so a restart resumes with no gap. A
    background thread emits a periodic `alive` heartbeat so Sentinel can detect a dead daemon."""
    checkpoint = get_meta(c, "fsevents_checkpoint")
    if checkpoint is None:
        set_meta(c, "fsevents_checkpoint", current_event_id())
        checkpoint = get_meta(c, "fsevents_checkpoint")
        loki_push(cfg, "bootstrap", "checkpoint=%s" % checkpoint)
    cnt = {"synced": 0, "deleted": 0, "fails": 0, "bytes": 0, "date": time.strftime("%Y-%m-%d")}

    def cb(stream, info, n, paths, flags, ids):
        # Never let an exception escape the FSEvents C-callback — it would unwind the run loop
        # and exit the daemon (KeepAlive would restart it, but a bad path would loop forever).
        try:
            rescan = False; rels = set(); maxid = 0
            for p, f, i in zip(paths, flags, ids):
                if f & FL_HISTDONE: continue
                if f & (FL_MUSTSCAN | FL_USERDROP | FL_KERNDROP): rescan = True
                iv = int(i)
                if iv and iv != 0xFFFFFFFFFFFFFFFF: maxid = max(maxid, iv)
                r = to_rel(p.decode("utf-8", "replace") if isinstance(p, bytes) else str(p), cfg.src)
                if r: rels.add(r)
            cnt["date"] = time.strftime("%Y-%m-%d")
            for rel in sorted(rels):
                try:
                    process_change(cfg, c, rel, cnt)
                except Exception as e:
                    loki_push(cfg, "cb_error", "rel=%s %s" % (rel[:60], str(e)[:100]))
            if maxid:
                set_meta(c, "fsevents_checkpoint", maxid)
            if rescan:
                loki_push(cfg, "must_rescan", "dropped events — run --reconcile")
        except Exception as e:
            loki_push(cfg, "cb_error", str(e)[:150])

    st = FE.FSEventStreamCreate(None, cb, None, [cfg.src], int(checkpoint), 1.0,
                                FE.kFSEventStreamCreateFlagFileEvents)
    FE.FSEventStreamScheduleWithRunLoop(st, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)
    FE.FSEventStreamStart(st)

    def heartbeat():
        while True:
            time.sleep(300)
            loki_push(cfg, "alive", "synced=%d deleted=%d fails=%d" % (cnt["synced"], cnt["deleted"], cnt["fails"]))
    threading.Thread(target=heartbeat, daemon=True).start()
    loki_push(cfg, "started", "mode=watch checkpoint=%s" % checkpoint)
    CFRunLoopRun()      # runs forever; launchd KeepAlive restarts us if we ever exit


def main():
    cfg = parse_args()
    if cfg.scan_only:
        for rel, (mt, sz) in scan(cfg.src).items():
            sys.stdout.write("%s\t%d\t%d\n" % (rel, mt, sz))
        return
    lock = open("/tmp/icloud-delta-%s.lock" % cfg.label, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        loki_push(cfg, "locked"); return
    if cfg.watch:
        watch(cfg, db_open(cfg.db))      # event-driven daemon; runs forever
        return
    t0 = time.time(); loki_push(cfg, "started")
    c = db_open(cfg.db)
    cnt = {"synced": 0, "deleted": 0, "fails": 0, "bytes": 0, "date": time.strftime("%Y-%m-%d")}
    checkpoint = get_meta(c, "fsevents_checkpoint")

    if checkpoint is None and not cfg.reconcile:
        set_meta(c, "fsevents_checkpoint", current_event_id())     # bootstrap: NO scan
        loki_push(cfg, "bootstrap", "checkpoint=%s" % get_meta(c, "fsevents_checkpoint"))
        print("bootstrap: checkpoint set to current fsevents id; manifest starts empty"); return

    new_cp = current_event_id()
    if cfg.reconcile:
        if do_reconcile(cfg, c, cnt):
            set_meta(c, "fsevents_checkpoint", new_cp)
    else:
        changed, must_rescan = fsevents_delta(cfg.src, int(checkpoint), cfg.drain_timeout)
        rels = set()
        for p in changed:
            r = to_rel(p, cfg.src)
            if r: rels.add(r)
        for rel in sorted(rels)[:cfg.batch_max]:
            process_change(cfg, c, rel, cnt)
        set_meta(c, "fsevents_checkpoint", new_cp)
        if must_rescan:
            loki_push(cfg, "must_rescan", "fsevents dropped events — run --reconcile")

    dl = c.execute("SELECT COUNT(*) FROM files WHERE state='deadletter'").fetchone()[0]
    tracked = c.execute("SELECT COUNT(*) FROM files").fetchone()[0]
    extra = ("synced=%d deleted=%d fails=%d deadletter=%d bytes=%d tracked=%d duration_s=%d"
             % (cnt["synced"], cnt["deleted"], cnt["fails"], dl, cnt["bytes"], tracked, int(time.time() - t0)))
    event = "synced" if (cnt["synced"] or cnt["deleted"]) else ("failed" if cnt["fails"] else "idle")
    loki_push(cfg, event, extra); print(extra)

if __name__ == "__main__":
    main()

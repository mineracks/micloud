#!/usr/bin/env python3
"""
icloud-notes-sync.py — Phase 6.3 of icloud-sovereign-backup.

Mac-Studio bridge that mirrors Apple Notes → Nextcloud Notes app by
parsing the local CoreData store directly. The AppleScript path that
worked for early-iOS Notes is now broken: every property access on a
modern CloudKit-backed note triggers a synchronous CloudKit fetch via
the Notes.app bridge, exactly the same hang we hit on Reminders. Even
`tell application "Notes" to count of notes` times out at -1712.

Apple has obfuscated the CoreData schema but it's been thoroughly
reverse-engineered. The bits we use:

    ZICCLOUDSYNCINGOBJECT  — entity table for everything (notes, folders, …)
        Z_ENT=12  → Note     (title=ZTITLE1, snippet=ZSNIPPET, folder=ZFOLDER,
                              identifier=ZIDENTIFIER, mod=ZMODIFICATIONDATE1)
        Z_ENT=15  → Folder   (title=ZTITLE2, type=ZFOLDERTYPE,
                              ZFOLDERTYPE=1 is "Recently Deleted" — skip)
    ZICNOTEDATA            — body blobs
        ZNOTE → ZICCLOUDSYNCINGOBJECT.Z_PK
        ZDATA → gzip(protobuf(Document)). Body text lives at field path 2→2
                (top-level message → Document → Note → text).

Output:
    Nextcloud Notes app via REST v1: POST/PUT/DELETE
    /index.php/apps/notes/api/v1/notes — `{title, content, category, modified}`.
    `category` is a flat folder name (Apple Notes folders aren't deeply
    nested — Apple's UI treats it as a flat list per account).

Manifest:
    ~/Library/Logs/icloud-notes-sync/manifest.json — keyed by ZIDENTIFIER.
    Stores nc_id, sha (of {title,body,category}), modified.

Anti-patterns (already paid for):
- Don't try AppleScript. The CloudKit-fetch hang is exactly Reminders'
  problem. EventKit doesn't cover Notes either — it's its own framework.
- Don't try to roundtrip the protobuf format back to Apple. Read-only.
- Don't sync the "Recently Deleted" folder (ZFOLDERTYPE=1) — those are
  notes the user explicitly trashed.
"""

import os
import sys
import json
import time
import gzip
import shlex
import sqlite3
import hashlib
import syslog
from pathlib import Path
from datetime import datetime, timezone

import urllib.request
import urllib.error
from base64 import b64encode


# ---------- Constants ----------
LOG_TAG = "icloud-notes-sync"
try:
    import micloud_config as mc
except ImportError:
    class mc:
        get = staticmethod(lambda k, d=None: __import__("os").environ.get(k) or d)
LOKI_URL = mc.get("MICLOUD_LOKI_URL", "http://LOKI_HOST:3100/loki/api/v1/push")
LOKI_LABELS = {"job": "icloud_notes", "host": "mac-studio", "unit": "icloud-notes-sync"}

ENV_FILE = Path.home() / ".config" / "icloud-notes" / "env"
ENV_FALLBACK = Path.home() / ".config" / "icloud-reminders-cloudkit" / "env"
NOTESTORE = Path.home() / "Library" / "Group Containers" / "group.com.apple.notes" / "NoteStore.sqlite"
MANIFEST_DIR = Path.home() / "Library" / "Logs" / "icloud-notes-sync"
MANIFEST_FILE = MANIFEST_DIR / "manifest.json"

# CFAbsoluteTime epoch is 2001-01-01 UTC; offset to unix epoch.
COCOA_EPOCH_OFFSET = 978307200


# ---------- Heartbeats ----------
def _loki_push(line):
    try:
        ns_ts = str(int(time.time() * 1e9))
        body = json.dumps({"streams": [{"stream": LOKI_LABELS, "values": [[ns_ts, line]]}]}).encode()
        req = urllib.request.Request(LOKI_URL, method="POST", data=body,
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=3).read()
    except Exception:
        pass


def hb(level, **kvs):
    parts = [level] + [f"{k}={shlex.quote(str(v)) if ' ' in str(v) else v}" for k, v in kvs.items()]
    msg = " ".join(parts)
    syslog.openlog(LOG_TAG, syslog.LOG_PID, syslog.LOG_USER)
    syslog.syslog(syslog.LOG_INFO, msg)
    syslog.closelog()
    print(msg, file=sys.stderr, flush=True)
    _loki_push(msg)


# ---------- Env / manifest ----------
def load_env():
    path = ENV_FILE if ENV_FILE.exists() else ENV_FALLBACK
    if not path.exists():
        raise RuntimeError(f"env file missing: {ENV_FILE} (and fallback {ENV_FALLBACK})")
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"').strip("'")
    for required in ("NEXTCLOUD_USERNAME", "NEXTCLOUD_APP_PASSWORD"):
        if not env.get(required):
            raise RuntimeError(f"missing env key: {required}")
    env.setdefault("NEXTCLOUD_BASE", "https://nextcloud.example.com")
    return env


def load_manifest():
    if not MANIFEST_FILE.exists():
        return {}
    try:
        return json.loads(MANIFEST_FILE.read_text())
    except Exception:
        return {}


def save_manifest(manifest):
    MANIFEST_DIR.mkdir(parents=True, exist_ok=True)
    tmp = MANIFEST_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(manifest, indent=2, sort_keys=True))
    tmp.replace(MANIFEST_FILE)


# ---------- Apple Notes protobuf decoding ----------
def _read_varint(buf, i):
    n = 0; shift = 0
    while True:
        b = buf[i]; i += 1
        n |= (b & 0x7f) << shift
        if not (b & 0x80):
            return n, i
        shift += 7


def _walk_message(buf):
    """Yield (field_number, wire_type, payload_bytes_or_value, start_index).

    Tolerant of truncated / mis-framed input: any decode error short-circuits
    the iteration cleanly. We don't need a strict parser — we're scraping
    text out of an opaque (but stable-shape) format, and Apple has more
    fields than we model.
    """
    n = len(buf)
    i = 0
    while i < n:
        try:
            tag, i = _read_varint(buf, i)
            field = tag >> 3
            wire = tag & 7
            if wire == 0:
                v, i = _read_varint(buf, i)
                yield field, wire, v, None
            elif wire == 1:
                if i + 8 > n:
                    return
                yield field, wire, buf[i:i+8], None
                i += 8
            elif wire == 5:
                if i + 4 > n:
                    return
                yield field, wire, buf[i:i+4], None
                i += 4
            elif wire == 2:
                ln, i = _read_varint(buf, i)
                if ln < 0 or i + ln > n:
                    return
                yield field, wire, buf[i:i+ln], None
                i += ln
            else:
                return
        except Exception:
            return


def _get_field2(msg_bytes):
    """Return the bytes payload of the first wire-type=2 entry at field 2."""
    for field, wire, payload, _ in _walk_message(msg_bytes):
        if field == 2 and wire == 2:
            return payload
    return None


def extract_note_text(zdata_blob):
    """gunzip → walk protobuf → return body text or None.

    The Apple Notes "Document" message has its content at field 2 → field 2,
    where the inner field 2 is the visible text string (with attribute_runs
    in sibling fields for formatting that we ignore in V1).
    """
    if not zdata_blob:
        return None
    try:
        decompressed = gzip.decompress(zdata_blob)
    except Exception:
        return None
    # Top-level → Document
    document = _get_field2(decompressed)
    if document is None:
        # Some old notes lay out differently — fall back to greedy text scan.
        return _greedy_text_scan(decompressed)
    # Document → Note (also at field 2)
    note_body = _get_field2(document)
    if note_body is None:
        return _greedy_text_scan(decompressed)
    # The body bytes start with the visible text (wire-type 2 string at field 2),
    # followed by attribute_runs. So walk one more level: the first field-2
    # wire-2 entry IS the text.
    text_bytes = _get_field2(note_body)
    if text_bytes is None:
        return _greedy_text_scan(decompressed)
    try:
        return text_bytes.decode("utf-8", "replace")
    except Exception:
        return _greedy_text_scan(decompressed)


def _greedy_text_scan(decompressed):
    """Last-ditch fallback: collect printable strings ≥3 chars and join the longest one."""
    candidates = []
    def recurse(buf, depth=0):
        if depth > 8:
            return
        for field, wire, payload, _ in _walk_message(buf):
            if wire != 2:
                continue
            try:
                s = payload.decode("utf-8")
                if len(s) >= 3 and any(c.isalpha() for c in s):
                    printable = sum(1 for c in s if c.isprintable() or c in "\n\t\r")
                    if printable / len(s) > 0.85:
                        candidates.append(s)
                        continue
            except Exception:
                pass
            if len(payload) > 1:
                recurse(payload, depth + 1)
    recurse(decompressed)
    if not candidates:
        return None
    return max(candidates, key=len)


# ---------- Nextcloud Notes REST v1 ----------
class NCNotesClient:
    def __init__(self, base, user, pw):
        self.base = base.rstrip("/")
        self.auth = "Basic " + b64encode(f"{user}:{pw}".encode()).decode("ascii")

    def _request(self, method, path, data=None, timeout=15):
        url = f"{self.base}/index.php/apps/notes/api/v1/{path.lstrip('/')}"
        body = None
        headers = {
            "Authorization": self.auth,
            "Accept": "application/json",
            "User-Agent": "icloud-notes-sync/1.0",
        }
        if data is not None:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, method=method, data=body, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=timeout)
            text = resp.read().decode("utf-8", "replace") or "null"
            return resp.status, json.loads(text)
        except urllib.error.HTTPError as e:
            try:
                detail = json.loads(e.read().decode("utf-8", "replace") or "{}")
            except Exception:
                detail = {}
            return e.code, detail

    def create(self, title, content, category, modified):
        code, body = self._request("POST", "notes", data={
            "title": title or "(untitled)",
            "content": content or "",
            "category": category or "",
            "modified": modified,
            "favorite": False,
        })
        if code in (200, 201):
            return body.get("id")
        raise RuntimeError(f"create note failed: {code} {body}")

    def update(self, nc_id, title, content, category, modified):
        code, body = self._request("PUT", f"notes/{nc_id}", data={
            "title": title or "(untitled)",
            "content": content or "",
            "category": category or "",
            "modified": modified,
        })
        return code in (200, 201)

    def delete(self, nc_id):
        code, _ = self._request("DELETE", f"notes/{nc_id}")
        return code in (200, 204, 404)


# ---------- Apple Notes enumeration ----------
def enumerate_apple_notes():
    """Yield dicts: {id, title, body, category, modified_unix} for every
    user-visible note. Skips 'Recently Deleted' (ZFOLDERTYPE=1) and
    notes marked for deletion.

    Reads against a snapshot copy of NoteStore.sqlite + sidecar files. The
    live store is held under an exclusive lock by Notes.app (especially
    the -wal where most recent edits live), and Apple's documented backup
    pattern is "copy main + sidecars then open the copy". `immutable=1` on
    the live store would let us bypass the lock, but it also bypasses the
    WAL — Notes.app keeps a large unflushed working set there, so we'd
    miss the bulk of the user's data. The copy approach gives us a fully
    consistent snapshot.
    """
    if not NOTESTORE.exists():
        raise RuntimeError(f"NoteStore.sqlite not found at {NOTESTORE}")

    import shutil, tempfile
    snapshot_dir = Path(tempfile.mkdtemp(prefix="notesync-"))
    try:
        snapshot_main = snapshot_dir / "NoteStore.sqlite"
        for suffix in ("", "-wal", "-shm"):
            src = NOTESTORE.with_suffix(NOTESTORE.suffix + suffix) if suffix else NOTESTORE
            if src.exists():
                shutil.copy2(src, snapshot_dir / src.name)

        uri = f"file:{snapshot_main}?mode=ro"
        conn = sqlite3.connect(uri, uri=True)
        try:
            cur = conn.cursor()
            cur.execute("""
                SELECT n.ZIDENTIFIER,
                       n.ZTITLE1,
                       n.ZSNIPPET,
                       n.ZMODIFICATIONDATE1,
                       COALESCE(f.ZTITLE2, '') AS folder,
                       COALESCE(f.ZFOLDERTYPE, 0) AS folder_type,
                       b.ZDATA
                  FROM ZICCLOUDSYNCINGOBJECT n
                  LEFT JOIN ZICNOTEDATA b ON b.ZNOTE = n.Z_PK
                  LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
                 WHERE n.Z_ENT = 12
                   AND COALESCE(n.ZMARKEDFORDELETION, 0) = 0
                   AND COALESCE(f.ZFOLDERTYPE, 0) != 1
            """)
            for ident, title, snippet, mod, folder, folder_type, zdata in cur.fetchall():
                if not ident:
                    continue
                text = extract_note_text(zdata) or ""
                # Apple's title is duplicated as the first line of `text` (the
                # visible body includes the title line). For Nextcloud Notes we
                # split: the Notes app uses `title` separately and `content`
                # for body. Drop the leading title line from content if present.
                content = text
                if title:
                    first_line, sep, rest = text.partition("\n")
                    if first_line.strip() == (title or "").strip():
                        content = rest.lstrip("\n")
                modified_unix = int(mod + COCOA_EPOCH_OFFSET) if mod else int(time.time())
                yield {
                    "id":            str(ident),
                    "title":         (title or snippet or "(untitled)").strip(),
                    "content":       content,
                    "category":      folder or "Notes",
                    "modified_unix": modified_unix,
                }
        finally:
            conn.close()
    finally:
        shutil.rmtree(snapshot_dir, ignore_errors=True)


# ---------- Sync ----------
def note_sha(note):
    canon = json.dumps({"title": note["title"],
                        "content": note["content"],
                        "category": note["category"]}, sort_keys=True)
    return hashlib.sha256(canon.encode()).hexdigest()


SANITY_DROP_THRESHOLD = 0.10  # refuse to apply deletions if count drops >10%


def sync():
    start = time.time()
    env = load_env()
    nc = NCNotesClient(env["NEXTCLOUD_BASE"], env["NEXTCLOUD_USERNAME"], env["NEXTCLOUD_APP_PASSWORD"])
    manifest = load_manifest()
    new_manifest = {}

    pushed = changed = deleted = errors = unchanged = 0
    total = 0
    seen = set()

    # Sanity gate: peek at the source count before doing any work. If it has
    # dropped more than SANITY_DROP_THRESHOLD vs the prior manifest, refuse
    # to sync — better to alert and let a human look than to mirror a
    # corrupted/half-synced local store into Nextcloud as a wave of
    # deletions. Mirrors Phase-2's photo-sync gate after the manifest-wipe
    # incident. Skipped on first run (manifest empty).
    prior_count = len(manifest)
    if prior_count > 0:
        notes_iter = list(enumerate_apple_notes())  # materialise once for the gate
        current_count = len(notes_iter)
        drop = (prior_count - current_count) / prior_count
        if drop > SANITY_DROP_THRESHOLD:
            hb("FAIL", event="sanity_gate_tripped",
               prior=prior_count, current=current_count,
               drop_pct=round(drop * 100, 1),
               note="refusing to sync — investigate Notes.app local store before re-running")
            sys.exit(2)
        notes_source = notes_iter
    else:
        notes_source = enumerate_apple_notes()

    for note in notes_source:
        total += 1
        rid = note["id"]
        seen.add(rid)
        sha = note_sha(note)
        prior = manifest.get(rid)
        try:
            if prior and prior.get("sha") == sha and prior.get("nc_id"):
                new_manifest[rid] = prior
                unchanged += 1
                continue
            if prior and prior.get("nc_id"):
                ok = nc.update(prior["nc_id"], note["title"], note["content"],
                               note["category"], note["modified_unix"])
                if ok:
                    new_manifest[rid] = {"nc_id": prior["nc_id"], "sha": sha,
                                         "modified": note["modified_unix"]}
                    changed += 1
                else:
                    errors += 1
                    new_manifest[rid] = prior
            else:
                nc_id = nc.create(note["title"], note["content"],
                                  note["category"], note["modified_unix"])
                if nc_id:
                    new_manifest[rid] = {"nc_id": int(nc_id), "sha": sha,
                                         "modified": note["modified_unix"]}
                    pushed += 1
                else:
                    errors += 1
        except Exception as e:
            hb("WARN", event="note_failed", title=note["title"][:60],
               reason=f"{type(e).__name__}:{str(e)[:120]}")
            errors += 1
            if prior:
                new_manifest[rid] = prior

    # Detect deletions
    for rid, slot in manifest.items():
        if rid in seen:
            continue
        if slot.get("nc_id") and nc.delete(slot["nc_id"]):
            deleted += 1
        else:
            errors += 1

    save_manifest(new_manifest)

    elapsed = int(time.time() - start)
    if pushed + changed + deleted == 0:
        hb("OK", event="idle", elapsed=f"{elapsed}s",
           total=total, unchanged=unchanged, errors=errors)
    else:
        hb("OK", event="synced", elapsed=f"{elapsed}s",
           total=total, pushed=pushed, changed=changed, deleted=deleted,
           unchanged=unchanged, errors=errors)


def main():
    hb("OK", event="started", host=os.uname().nodename)
    try:
        sync()
        sys.exit(0)
    except Exception as ex:
        hb("FAIL", event="failed", exception=f"{type(ex).__name__}:{str(ex)[:200]}")
        sys.exit(1)


if __name__ == "__main__":
    main()

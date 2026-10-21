#!/usr/bin/env python3
"""
icloud-bookmarks-sync.py — Phase 6.2 of icloud-sovereign-backup.

Mac-Studio-side bridge that mirrors Safari's `~/Library/Safari/Bookmarks.plist`
(which Apple keeps in lock-step with iCloud Bookmarks via CloudKit) into the
Nextcloud Bookmarks app at nextcloud.example.com.

Source       Safari `Bookmarks.plist` — well-known plist format, parsed via
             stdlib `plistlib`. No AppleScript / private API. The plist is
             NOT under `~/Library/Group Containers/...` so launchd
             `WatchPaths` works directly (unlike Reminders, where Group
             Container TCC blocks FSEvents).

Destination  Nextcloud Bookmarks app's REST v2 API at
             /index.php/apps/bookmarks/public/rest/v2/{bookmark,folder}.
             We mirror Safari's folder hierarchy under a root folder named
             "iCloud Bookmarks" so the user-visible namespace is clearly
             provenance-tagged.

One-way      This script only reads from Safari. Nextcloud is the writable
             surface for any user-facing edits the operator wants to make
             on the mirror.

Manifest     ~/Library/Logs/icloud-bookmarks-sync/manifest.json
             {
               "folders":   {"<safari-folder-path>": {"nc_id": <int>}},
               "bookmarks": {"<safari-uuid>":
                              {"nc_id": <int>, "sha": <hex>,
                               "folder_path": "...", "url": "...", "title": "..."}}
             }

Heartbeats   Same `hb()` helper as the Reminders sync — syslog + stderr +
             Loki HTTP push to logs:3100. Sentinel rule keys on
             `event=synced|idle` from `unit="icloud-bookmarks-sync"`.

Anti-patterns:
- Don't try to mirror Reading List article *content* (Safari's reading
  list snapshot is a binary blob in a different store). Just sync the URLs.
- Don't dedupe by URL only — Safari allows the same URL in multiple
  folders. Use the Safari UUID as the canonical id.
- Don't delete the Nextcloud root folder if it goes empty — could be
  user-visible churn. Deletions of bookmarks within it are fine.
"""

import os
import sys
import json
import time
import shlex
import hashlib
import plistlib
import syslog
from pathlib import Path
from urllib.parse import quote
from datetime import datetime, timezone

import urllib.request
import urllib.error
from base64 import b64encode


# ---------- Constants ----------
LOG_TAG = "icloud-bookmarks-sync"
try:
    import micloud_config as mc
except ImportError:
    class mc:
        get = staticmethod(lambda k, d=None: __import__("os").environ.get(k) or d)
LOKI_URL = mc.get("MICLOUD_LOKI_URL", "http://LOKI_HOST:3100/loki/api/v1/push")
LOKI_LABELS = {
    "job":  "icloud_bookmarks",
    "host": "mac-studio",
    "unit": "icloud-bookmarks-sync",
}

ENV_FILE = Path.home() / ".config" / "icloud-bookmarks" / "env"
ENV_FALLBACK = Path.home() / ".config" / "icloud-reminders-cloudkit" / "env"
SAFARI_PLIST = Path.home() / "Library" / "Safari" / "Bookmarks.plist"
MANIFEST_DIR = Path.home() / "Library" / "Logs" / "icloud-bookmarks-sync"
MANIFEST_FILE = MANIFEST_DIR / "manifest.json"

# Top-level folder name in Nextcloud Bookmarks. Everything from Safari
# nests under this so the user can distinguish iCloud-mirror bookmarks
# from anything they might add directly to NC.
NC_ROOT_FOLDER_TITLE = "iCloud Bookmarks"

# Skip these top-level Safari nodes — they aren't user bookmarks.
SAFARI_SKIP_TOPLEVEL = {"History"}


# ---------- Heartbeats ----------
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
        return {"folders": {}, "bookmarks": {}}
    try:
        m = json.loads(MANIFEST_FILE.read_text())
        m.setdefault("folders", {})
        m.setdefault("bookmarks", {})
        return m
    except Exception:
        return {"folders": {}, "bookmarks": {}}


def save_manifest(manifest):
    MANIFEST_DIR.mkdir(parents=True, exist_ok=True)
    tmp = MANIFEST_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(manifest, indent=2, sort_keys=True))
    tmp.replace(MANIFEST_FILE)


# ---------- Safari plist ----------
def _friendly_folder_name(node):
    """Apple uses opaque internal names for top-level lists. Map to user-visible."""
    title = node.get("Title") or ""
    return {
        "BookmarksBar":          "Favourites Bar",
        "BookmarksMenu":         "Bookmarks Menu",
        "com.apple.ReadingList": "Reading List",
    }.get(title, title)


def walk_safari_bookmarks():
    """Yield (folder_path_segments, bookmark_dict) tuples.

    bookmark_dict has: id, url, title, description.
    folder_path_segments is a list of strings, e.g. ["Favourites Bar", "Tech"].
    """
    if not SAFARI_PLIST.exists():
        raise RuntimeError(f"Safari Bookmarks.plist not found at {SAFARI_PLIST}")
    root = plistlib.load(open(SAFARI_PLIST, "rb"))

    def recurse(node, segs):
        wt = node.get("WebBookmarkType")
        if wt == "WebBookmarkTypeProxy":
            return  # History node etc. — not bookmarks
        if wt == "WebBookmarkTypeLeaf":
            uri = node.get("URLString")
            if not uri:
                return
            # Nextcloud Bookmarks rejects non-HTTP(S) URLs as "Invalid URL".
            # Safari stores `about:blank` / `safari-resource:` placeholders for
            # things like new-tab-page bookmarks; skip them silently.
            if not (uri.startswith("http://") or uri.startswith("https://")):
                return
            uri_dict = node.get("URIDictionary") or {}
            title = uri_dict.get("title") or node.get("Title") or uri
            yield list(segs), {
                "id":          node.get("WebBookmarkUUID") or hashlib.sha1(uri.encode()).hexdigest(),
                "url":         uri,
                "title":       title.strip(),
                "description": uri_dict.get("description") or "",
            }
            return
        # WebBookmarkTypeList — folder
        for child in node.get("Children") or []:
            child_t = child.get("Title") or ""
            if not segs and child_t in SAFARI_SKIP_TOPLEVEL:
                continue
            child_seg = _friendly_folder_name(child) if not segs else (child_t or "(unnamed)")
            child_wt = child.get("WebBookmarkType")
            if child_wt == "WebBookmarkTypeList":
                yield from recurse(child, segs + [child_seg])
            else:
                # Leaf at this level — its folder is segs (parent)
                yield from recurse(child, segs)

    yield from recurse(root, [])


# ---------- Nextcloud Bookmarks REST v2 ----------
class NCBookmarksClient:
    def __init__(self, base, user, pw):
        self.base = base.rstrip("/")
        self.auth = "Basic " + b64encode(f"{user}:{pw}".encode()).decode("ascii")

    def _request(self, method, path, params=None, data=None, timeout=15):
        url = f"{self.base}/index.php/apps/bookmarks/public/rest/v2/{path.lstrip('/')}"
        if params:
            qs = "&".join(f"{quote(str(k))}={quote(str(v))}" for k, v in params.items())
            url = f"{url}?{qs}"
        body = None
        headers = {
            "Authorization": self.auth,
            "Accept": "application/json",
            "User-Agent": "icloud-bookmarks-sync/1.0",
        }
        if data is not None:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, method=method, data=body, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=timeout)
            return resp.status, json.loads(resp.read().decode("utf-8", "replace") or "{}")
        except urllib.error.HTTPError as e:
            try:
                detail = json.loads(e.read().decode("utf-8", "replace") or "{}")
            except Exception:
                detail = {}
            return e.code, detail

    def list_folders(self, parent_id=-1):
        code, body = self._request("GET", "folder", params={"root": parent_id})
        if code == 200:
            return body.get("data") or []
        return []

    def create_folder(self, title, parent_id=-1):
        code, body = self._request("POST", "folder", data={"title": title, "parent_folder": parent_id})
        if code in (200, 201):
            return body.get("item", {}).get("id") or body.get("id")
        raise RuntimeError(f"create_folder failed: {code} {body}")

    def list_bookmarks_in_folder(self, folder_id, page=0, limit=200):
        code, body = self._request("GET", "bookmark", params={"folder": folder_id, "page": page, "limit": limit})
        if code == 200:
            return body.get("data") or []
        return []

    def create_bookmark(self, url, title, description, folder_ids):
        data = {
            "url":         url,
            "title":       title or url,
            "description": description or "",
            "folders":     folder_ids,
            "tags":        [],
        }
        code, body = self._request("POST", "bookmark", data=data)
        if code in (200, 201):
            item = body.get("item") or body
            return item.get("id")
        raise RuntimeError(f"create_bookmark failed: {code} {body}")

    def update_bookmark(self, bm_id, url, title, description, folder_ids):
        data = {
            "url":         url,
            "title":       title or url,
            "description": description or "",
            "folders":     folder_ids,
            "tags":        [],
        }
        code, body = self._request("PUT", f"bookmark/{bm_id}", data=data)
        return code in (200, 201)

    def delete_bookmark(self, bm_id):
        code, _ = self._request("DELETE", f"bookmark/{bm_id}")
        return code in (200, 204, 404)


# ---------- Folder hierarchy ----------
def ensure_folder_path(client, manifest_folders, segments):
    """Walk segments left-to-right, creating folders as needed. Caches in
    `manifest_folders` so subsequent runs don't re-fetch the whole tree.

    Returns the folder id that should hold bookmarks at this path.
    """
    parent = -1
    cur_path = ""
    for seg in segments:
        cur_path = (cur_path + "/" + seg).strip("/")
        slot = manifest_folders.get(cur_path)
        if slot and isinstance(slot.get("nc_id"), int):
            parent = slot["nc_id"]
            continue
        # Look up; create if missing.
        existing = client.list_folders(parent_id=parent)
        match = next((f for f in existing if (f.get("title") or "") == seg), None)
        if match:
            parent = int(match.get("id"))
        else:
            parent = int(client.create_folder(seg, parent_id=parent))
        manifest_folders[cur_path] = {"nc_id": parent}
    return parent


# ---------- Sync ----------
def bookmark_sha(bm):
    canon = json.dumps({
        "url":         bm["url"],
        "title":       bm.get("title", ""),
        "description": bm.get("description", ""),
    }, sort_keys=True)
    return hashlib.sha256(canon.encode()).hexdigest()


def sync():
    start = time.time()
    env = load_env()
    nc = NCBookmarksClient(env["NEXTCLOUD_BASE"], env["NEXTCLOUD_USERNAME"], env["NEXTCLOUD_APP_PASSWORD"])
    manifest = load_manifest()
    folders = manifest["folders"]
    prior_bookmarks = manifest["bookmarks"]
    new_bookmarks = {}

    pushed = changed = deleted = errors = unchanged = 0
    total = 0

    # Make sure the top-level "iCloud Bookmarks" folder exists.
    root_id = ensure_folder_path(nc, folders, [NC_ROOT_FOLDER_TITLE])

    seen_ids = set()
    for path_segs, bm in walk_safari_bookmarks():
        total += 1
        rid = bm["id"]
        seen_ids.add(rid)
        try:
            full_segs = [NC_ROOT_FOLDER_TITLE] + path_segs
            folder_id = ensure_folder_path(nc, folders, full_segs)
            sha = bookmark_sha(bm)
            prior = prior_bookmarks.get(rid)
            if prior and prior.get("sha") == sha and prior.get("nc_id"):
                # Unchanged — keep state, no PUT.
                new_bookmarks[rid] = prior
                unchanged += 1
                continue
            if prior and prior.get("nc_id"):
                ok = nc.update_bookmark(prior["nc_id"], bm["url"], bm["title"], bm["description"], [folder_id])
                if ok:
                    new_bookmarks[rid] = {"nc_id": prior["nc_id"], "sha": sha,
                                          "url": bm["url"], "title": bm["title"],
                                          "folder_path": "/".join(full_segs)}
                    changed += 1
                else:
                    errors += 1
                    new_bookmarks[rid] = prior
            else:
                nc_id = nc.create_bookmark(bm["url"], bm["title"], bm["description"], [folder_id])
                if nc_id:
                    new_bookmarks[rid] = {"nc_id": int(nc_id), "sha": sha,
                                          "url": bm["url"], "title": bm["title"],
                                          "folder_path": "/".join(full_segs)}
                    pushed += 1
                else:
                    errors += 1
        except Exception as e:
            hb("WARN", event="bookmark_failed",
               url=bm.get("url", "")[:80], reason=f"{type(e).__name__}:{str(e)[:120]}")
            errors += 1
            if rid in prior_bookmarks:
                new_bookmarks[rid] = prior_bookmarks[rid]

    # Detect deletions: items in prior manifest but not seen this run.
    for rid, slot in prior_bookmarks.items():
        if rid in seen_ids:
            continue
        nc_id = slot.get("nc_id")
        if nc_id and nc.delete_bookmark(nc_id):
            deleted += 1
        else:
            errors += 1

    manifest["folders"] = folders
    manifest["bookmarks"] = new_bookmarks
    save_manifest(manifest)

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

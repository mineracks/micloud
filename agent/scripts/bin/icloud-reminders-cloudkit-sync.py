#!/usr/bin/env python3
"""
icloud-reminders-cloudkit-sync.py — Phase 6.1.5 of icloud-sovereign-backup.

Mac-Studio-side bridge that captures the post-2018 Apple Reminders data
that iCloud's CalDAV endpoint deliberately hides (the CloudKit-only
modern Reminders), and pushes it as VTODO iCalendar entries into
Nextcloud Tasks at nextcloud.example.com.

Pipeline:
  1. Run the JXA enumerator (icloud-reminders-cloudkit-export.js) →
     JSON dump of every list and every reminder (incl. completed).
  2. For each list: MKCALENDAR a Nextcloud calendar at
     /remote.php/dav/calendars/<user>/tasks-cloudkit-<list-id>/ if
     missing, with `supported-calendar-component-set` = VTODO.
  3. For each reminder: build a minimal RFC 5545 VTODO and PUT to
     <collection>/<reminder-id>.ics. Diff against a per-run manifest so
     unchanged items are PUT only when modification_date moved.
  4. Detect deletions: items in prior manifest but no longer reported
     by Reminders.app → DELETE on Nextcloud.
  5. Emit Loki heartbeats via `logger -t icloud-reminders-cloudkit-sync`.

One-way guarantee: this script never instantiates a write operation on
Reminders.app — the JXA helper uses .reminders() / .lists() / property
getters only. iCloud is touched via Apple's normal Reminders sync
outside this process.

Configuration (environment variables, sourced from
~/.config/icloud-reminders-cloudkit/env, mode 600):
  NEXTCLOUD_USERNAME            - typically you@example.com
  NEXTCLOUD_APP_PASSWORD        - app-specific token from Nextcloud
  NEXTCLOUD_BASE                - https://nextcloud.example.com (default)

Manifest:
  ~/Library/Logs/icloud-reminders-cloudkit-sync/manifest.json
  Schema: { "<list-id>": { "<reminder-id>": {
              "modification_date": "...", "etag": "...", "filename": "<reminder-id>.ics"
           } } }

Heartbeat schema (single-line, key=value):
  event=started
  event=synced  pushed=N changed=N deleted=N errors=N elapsed=Ns lists=N reminders=N
  event=idle    elapsed=Ns errors=N (no changes)
  event=failed  exception=Type:msg elapsed=Ns

Lockfile (flock) is managed by the bash wrapper, NOT this script.
"""

import os
import sys
import json
import time
import shlex
import hashlib
import socket
import subprocess
import syslog
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote
from xml.etree import ElementTree as ET

import urllib.request
import urllib.error
from base64 import b64encode


# ---------- Constants ----------
LOG_TAG = "icloud-reminders-cloudkit-sync"
try:
    import micloud_config as mc
except ImportError:
    class mc:
        get = staticmethod(lambda k, d=None: __import__("os").environ.get(k) or d)
LOKI_URL = mc.get("MICLOUD_LOKI_URL", "http://LOKI_HOST:3100/loki/api/v1/push")
LOKI_LABELS = {
    "job":  "icloud_reminders_cloudkit",
    "host": "mac-studio",
    "unit": "icloud-reminders-cloudkit-sync",
}
ENV_FILE = Path.home() / ".config" / "icloud-reminders-cloudkit" / "env"
MANIFEST_DIR = Path.home() / "Library" / "Logs" / "icloud-reminders-cloudkit-sync"
MANIFEST_FILE = MANIFEST_DIR / "manifest.json"


# ---------- Helpers ----------
def _loki_push(line):
    """Best-effort POST one log line to Loki. Failures are silently swallowed
    — Loki being unreachable must never block a sync run.

    Mac Studio doesn't run Promtail; the same direct-push pattern is used
    by icloud-drive-sync.sh, immich-photo-sync.sh, etc. Centralised host
    is the logs VM (LOKI_HOST:3100).
    """
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
    """Emit a heartbeat: syslog + stderr (for the local log file) + Loki HTTP push."""
    parts = [level] + [f"{k}={shlex.quote(str(v)) if ' ' in str(v) else v}" for k, v in kvs.items()]
    msg = " ".join(parts)
    syslog.openlog(LOG_TAG, syslog.LOG_PID, syslog.LOG_USER)
    syslog.syslog(syslog.LOG_INFO, msg)
    syslog.closelog()
    # stderr with flush=True so launchd's StandardErrorPath shows progress
    # in real time during long runs (without it Python buffers and the file
    # stays empty for 20+ min during a bulk push).
    print(msg, file=sys.stderr, flush=True)
    _loki_push(msg)


def load_env():
    if not ENV_FILE.exists():
        raise RuntimeError(f"env file missing: {ENV_FILE}")
    env = {}
    for line in ENV_FILE.read_text().splitlines():
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


def enumerate_reminders():
    """Enumerate every list and every reminder via EventKit (Cocoa).

    The original implementation drove this through AppleScript / JXA against
    Reminders.app. That bridge turned out to be unworkable on a real fleet:
    each property access on a CloudKit-backed reminder triggers a lazy fetch
    that can take seconds, so a 90-reminder list took >5 minutes and bigger
    lists never completed at all. Switching to EventKit's synchronous
    `remindersMatchingPredicate:` does the entire 48-list / ~2300-reminder
    sweep in well under a second on a warm cache.

    Side benefit: EventKit gives us stable `calendarItemExternalIdentifier`
    UUIDs (the same IDs Apple's iCloud sync uses), so VTODO filenames stay
    stable across runs without us having to keep our own UUID map.

    TCC: needs Reminders Full Access on whatever ends up being the
    responsible process (sshd-keygen-wrapper for SSH-driven runs, the
    LaunchAgent's bash binary for launchd-driven runs). The macOS
    `authorizationStatusForEntityType:` check below makes the failure
    mode explicit rather than producing an empty enumeration.
    """
    import objc
    from Foundation import NSBundle

    EK = NSBundle.bundleWithPath_("/System/Library/Frameworks/EventKit.framework")
    if not EK or not EK.load():
        raise RuntimeError("could not load EventKit.framework")

    EKEventStore = objc.lookUpClass("EKEventStore")
    EK_ENTITY_REMINDER = 1  # EKEntityTypeReminder

    auth = EKEventStore.authorizationStatusForEntityType_(EK_ENTITY_REMINDER)
    # 0=NotDetermined, 1=Restricted, 2=Denied, 3=Authorized (legacy),
    # 4=WriteOnly, 5=FullAccess (macOS 14+)
    if auth not in (3, 5):
        raise RuntimeError(
            f"EventKit reminders access not granted (status={auth}). "
            "Add the responsible process to System Settings → Privacy & "
            "Security → Reminders."
        )

    store = EKEventStore.alloc().init()
    calendars = store.calendarsForEntityType_(EK_ENTITY_REMINDER)
    if calendars is None or calendars.count() == 0:
        return []

    out = []
    for i in range(calendars.count()):
        cal = calendars.objectAtIndex_(i)
        list_id = str(cal.calendarIdentifier())
        list_name = str(cal.title()) if cal.title() else f"(unnamed list {i})"
        predicate = store.predicateForRemindersInCalendars_([cal])
        rems = store.remindersMatchingPredicate_(predicate)
        items = []
        if rems is not None:
            for j in range(rems.count()):
                r = rems.objectAtIndex_(j)
                items.append(_reminder_to_dict(r))
        out.append({
            "list_id":   list_id,
            "list_name": list_name,
            "reminders": items,
        })
    return out


def _reminder_to_dict(r):
    """Map an EKReminder to the same dict shape the rest of this script expects."""
    # `calendarItemExternalIdentifier` is the cloud-stable UUID (matches
    # what Reminders.app exposes via AppleScript `id`). Fall back to the
    # local-only `calendarItemIdentifier` if that's nil (rare; happens for
    # items that haven't synced).
    rid = r.calendarItemExternalIdentifier() or r.calendarItemIdentifier()
    title = r.title()
    notes = r.notes()
    completion_date = r.completionDate()
    last_modified = r.lastModifiedDate()
    creation = r.creationDate()
    priority = int(r.priority()) if r.priority() is not None else 0

    # Due date is exposed as NSDateComponents on EKReminder. If hour/minute
    # components are unset (NSDateComponentUndefined == NSIntegerMax), it's
    # an all-day due. Otherwise, build a wall-clock datetime in the calendar's
    # timezone.
    due_iso = None
    allday_due_iso = None
    dc = r.dueDateComponents()
    if dc is not None:
        cal = dc.calendar() or _gregorian_calendar()
        # NSDateComponentUndefined surfaces in PyObjC as a huge int.
        UNDEFINED = (1 << 63) - 1  # NSIntegerMax on 64-bit
        try:
            hour = int(dc.hour())
        except Exception:
            hour = UNDEFINED
        date = cal.dateFromComponents_(dc)
        if date is not None:
            iso = _nsdate_to_iso(date)
            if hour == UNDEFINED:
                allday_due_iso = iso
            else:
                due_iso = iso

    return {
        "id":                str(rid) if rid else None,
        "name":              str(title) if title else None,
        "body":              str(notes) if notes else None,
        "completed":         bool(r.isCompleted()),
        "completion_date":   _nsdate_to_iso(completion_date),
        "due_date":          due_iso,
        "alldayDueDate":     allday_due_iso,
        "creation_date":     _nsdate_to_iso(creation),
        "modification_date": _nsdate_to_iso(last_modified),
        "priority":          priority,
    }


def _gregorian_calendar():
    from Foundation import NSCalendar, NSCalendarIdentifierGregorian
    return NSCalendar.alloc().initWithCalendarIdentifier_(NSCalendarIdentifierGregorian)


def _nsdate_to_iso(d):
    if d is None:
        return None
    # NSDate → POSIX → datetime
    return datetime.fromtimestamp(d.timeIntervalSince1970(), tz=timezone.utc).isoformat()


# ---------- HTTP / WebDAV ----------
class WriteSession:
    """Tiny urllib-backed HTTP client for Nextcloud writes.

    Built on stdlib so the script has no third-party dependencies — runs
    on a vanilla macOS install with system Python. Requests-style ergonomics
    aren't worth a dependency on a Mac you don't fully control.
    """

    def __init__(self, base, user, pw, ua):
        self.base = base.rstrip("/")
        self.user = user
        self.auth_b64 = b64encode(f"{user}:{pw}".encode()).decode("ascii")
        self.ua = ua

    def request(self, method, url, data=None, headers=None, timeout=60):
        if not url.startswith("http"):
            url = self.base + url
        h = {
            "Authorization": f"Basic {self.auth_b64}",
            "User-Agent": self.ua,
        }
        if headers:
            h.update(headers)
        if isinstance(data, str):
            data = data.encode("utf-8")
        req = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            resp = urllib.request.urlopen(req, timeout=timeout)
            return resp.status, resp.read(), dict(resp.getheaders())
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers or {})


# ---------- WebDAV ops ----------
NS = {"d": "DAV:", "cal": "urn:ietf:params:xml:ns:caldav"}


def collection_exists(sess, url):
    body = (
        '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:resourcetype/></d:prop>'
        '</d:propfind>'
    ).encode("utf-8")
    code, _, _ = sess.request("PROPFIND", url, data=body, headers={"Depth": "0"})
    return code in (200, 207)


def mkcalendar(sess, url, display_name):
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<cal:mkcalendar xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">'
        '<d:set><d:prop>'
        f'<d:displayname>{xml_escape(display_name)}</d:displayname>'
        '<cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>'
        '</d:prop></d:set>'
        '</cal:mkcalendar>'
    ).encode("utf-8")
    code, body_bytes, _ = sess.request(
        "MKCALENDAR", url,
        data=body,
        headers={"Content-Type": "application/xml; charset=utf-8"},
    )
    return code in (201, 207), code, body_bytes


def list_collection_filenames(sess, url):
    """Return list of {filename: etag} for VTODO items in a collection."""
    body = (
        '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:getetag/></d:prop>'
        '</d:propfind>'
    ).encode("utf-8")
    code, content, _ = sess.request(
        "PROPFIND", url, data=body, headers={"Depth": "1"},
    )
    if code not in (200, 207):
        return {}
    out = {}
    root = ET.fromstring(content)
    for resp in root.findall("d:response", NS):
        href = resp.find("d:href", NS)
        etag = resp.find(".//d:getetag", NS)
        if href is None or not href.text:
            continue
        if not href.text.lower().endswith(".ics"):
            continue
        if etag is None or not etag.text:
            continue
        fn = href.text.rstrip("/").rsplit("/", 1)[-1]
        out[fn] = etag.text.strip('"')
    return out


def put_vtodo(sess, url, data):
    code, body, headers = sess.request(
        "PUT", url, data=data,
        headers={"Content-Type": "text/calendar; charset=utf-8"},
    )
    return code in (200, 201, 204), code, body


def delete_item(sess, url):
    code, _, _ = sess.request("DELETE", url)
    return code in (200, 204, 404)


def xml_escape(s):
    return (
        s.replace("&", "&amp;")
         .replace("<", "&lt;")
         .replace(">", "&gt;")
         .replace('"', "&quot;")
    )


# ---------- VTODO generation ----------
def parse_iso(s):
    """Parse 2026-05-07T09:30:00.000Z or 2026-05-07T09:30:00+00:00 → aware datetime."""
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    # Trim sub-second precision for cleanliness; iCal handles second resolution fine.
    if "." in s:
        head, _, tail = s.rpartition(".")
        # tail is e.g. "000+00:00" — keep the offset
        plus = tail.find("+")
        minus = tail.find("-")
        offset_idx = max(plus, minus)
        if offset_idx >= 0:
            s = head + tail[offset_idx:]
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return None


def fmt_utc(dt):
    """Format as iCal UTC: 20260507T093000Z (no milliseconds)."""
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y%m%dT%H%M%SZ")


def fmt_date(dt):
    """Format as iCal date: 20260507."""
    return dt.strftime("%Y%m%d")


def ical_fold(line, max_len=75):
    """RFC 5545 line folding: max 75 octets per line; continuation lines
    start with a single space."""
    if len(line.encode("utf-8")) <= max_len:
        return line
    out = []
    while line:
        chunk = line[:max_len]
        # Avoid splitting in the middle of a multi-byte UTF-8 sequence; back off.
        while chunk.encode("utf-8", errors="ignore").decode("utf-8", errors="ignore") != chunk:
            chunk = chunk[:-1]
        out.append(chunk)
        line = " " + line[len(chunk):]
        if len(line) <= max_len + 1:
            out.append(line)
            line = ""
    return "\r\n".join(out)


def ical_escape_text(s):
    """RFC 5545 text escaping for SUMMARY/DESCRIPTION."""
    if s is None:
        return ""
    return (
        s.replace("\\", "\\\\")
         .replace(";", "\\;")
         .replace(",", "\\,")
         .replace("\n", "\\n")
         .replace("\r", "")
    )


def build_vtodo(rem):
    """Build a minimal RFC 5545 VTODO from one Reminders.app reminder dict."""
    lines = []
    lines.append("BEGIN:VCALENDAR")
    lines.append("VERSION:2.0")
    lines.append("PRODID:-//mineracks//icloud-reminders-cloudkit-sync 1.0//EN")
    lines.append("BEGIN:VTODO")
    lines.append(f"UID:{rem['id']}")
    if rem.get("creation_date"):
        d = parse_iso(rem["creation_date"])
        if d:
            lines.append(f"CREATED:{fmt_utc(d)}")
            lines.append(f"DTSTAMP:{fmt_utc(d)}")
    if rem.get("modification_date"):
        d = parse_iso(rem["modification_date"])
        if d:
            lines.append(f"LAST-MODIFIED:{fmt_utc(d)}")
            # If we have a modification date but no creation, still need DTSTAMP.
            if not any(line.startswith("DTSTAMP:") for line in lines):
                lines.append(f"DTSTAMP:{fmt_utc(d)}")
    if not any(line.startswith("DTSTAMP:") for line in lines):
        # Fall back to now to satisfy DTSTAMP requirement.
        lines.append(f"DTSTAMP:{fmt_utc(datetime.now(timezone.utc))}")

    if rem.get("name"):
        lines.append(ical_fold(f"SUMMARY:{ical_escape_text(rem['name'])}"))
    if rem.get("body"):
        lines.append(ical_fold(f"DESCRIPTION:{ical_escape_text(rem['body'])}"))

    # DUE — prefer alldayDueDate (DATE-only) when present; else due_date (DATE-TIME).
    if rem.get("alldayDueDate"):
        d = parse_iso(rem["alldayDueDate"])
        if d:
            lines.append(f"DUE;VALUE=DATE:{fmt_date(d)}")
    elif rem.get("due_date"):
        d = parse_iso(rem["due_date"])
        if d:
            lines.append(f"DUE:{fmt_utc(d)}")

    # Status / completion
    if rem.get("completed"):
        lines.append("STATUS:COMPLETED")
        lines.append("PERCENT-COMPLETE:100")
        if rem.get("completion_date"):
            d = parse_iso(rem["completion_date"])
            if d:
                lines.append(f"COMPLETED:{fmt_utc(d)}")
    else:
        lines.append("STATUS:NEEDS-ACTION")

    pri = rem.get("priority") or 0
    if pri:
        lines.append(f"PRIORITY:{pri}")

    lines.append("END:VTODO")
    lines.append("END:VCALENDAR")
    return ("\r\n".join(lines) + "\r\n").encode("utf-8")


def list_url_segment(list_id):
    """Sanitise Apple list-id into a URL-safe Nextcloud collection name.

    Apple list-ids look like:
        x-coredata://AB12-CD34/REMCDList/p7
    We hash to 16 hex chars to stay short and stable.
    """
    h = hashlib.sha1(list_id.encode("utf-8")).hexdigest()[:16]
    return f"tasks-cloudkit-{h}"


def reminder_filename(reminder_id):
    """Sanitise Apple reminder-id into a .ics filename."""
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in reminder_id)
    return f"{safe[:120]}.ics"


# ---------- Main sync ----------
def sync():
    start = time.time()
    hb("OK", event="started", host=socket.gethostname())

    env = load_env()
    nc_user = env["NEXTCLOUD_USERNAME"]
    nc_pw = env["NEXTCLOUD_APP_PASSWORD"]
    nc_base = env["NEXTCLOUD_BASE"]
    nc_cal_base = f"/remote.php/dav/calendars/{quote(nc_user)}/"

    sess = WriteSession(nc_base, nc_user, nc_pw, ua="icloud-reminders-cloudkit-sync/1.0")
    manifest = load_manifest()
    new_manifest = {}

    pushed = changed = deleted = errors = 0
    list_count = reminder_count = 0

    enum_start = time.time()
    data = enumerate_reminders()
    enum_total = sum(len(l.get("reminders", [])) for l in data)
    hb("OK", event="enum_done", lists=len(data), reminders=enum_total,
       elapsed_ms=int((time.time() - enum_start) * 1000))
    list_count = len(data)
    for li, lst in enumerate(data):
        list_id = lst.get("list_id") or ""
        list_name = lst.get("list_name") or "(unnamed)"
        seg = list_url_segment(list_id)
        col_url = f"{nc_cal_base}{seg}/"
        list_t0 = time.time()
        list_pushed = list_changed = list_skipped = list_errors = 0

        # MKCALENDAR if missing.
        if not collection_exists(sess, col_url):
            ok, code, body = mkcalendar(sess, col_url, f"iCloud — {list_name}")
            if not ok:
                hb("WARN", event="mkcalendar_failed", list_name=list_name, code=code,
                   body_excerpt=body.decode("utf-8", "replace")[:200])
                errors += 1
                continue

        list_state = manifest.get(list_id, {})
        new_list_state = {}

        for rem in lst.get("reminders", []):
            if "error" in rem:
                hb("WARN", event="reminder_export_error", list_name=list_name,
                   error=rem["error"][:200])
                errors += 1
                continue
            rid = rem["id"]
            mod = rem.get("modification_date") or ""
            sha = hashlib.sha256(json.dumps(rem, sort_keys=True).encode()).hexdigest()
            fn = reminder_filename(rid)

            prior = list_state.get(rid)
            if prior and prior.get("sha") == sha:
                # Unchanged → keep state, no PUT.
                new_list_state[rid] = prior
                reminder_count += 1
                list_skipped += 1
                continue

            vtodo = build_vtodo(rem)
            ok, code, body = put_vtodo(sess, col_url + quote(fn), vtodo)
            if ok:
                new_list_state[rid] = {"mod": mod, "sha": sha, "fn": fn}
                if prior is None:
                    pushed += 1
                    list_pushed += 1
                else:
                    changed += 1
                    list_changed += 1
            else:
                hb("WARN", event="put_failed", list_name=list_name,
                   reminder_name=rem.get("name", "")[:60],
                   code=code,
                   body_excerpt=body.decode("utf-8", "replace")[:200])
                errors += 1
                list_errors += 1
                # Keep prior state so transient failure doesn't lose tracking.
                if prior is not None:
                    new_list_state[rid] = prior
            reminder_count += 1

        # Detect deletions: items in prior state but not in current export.
        seen_ids = {r["id"] for r in lst.get("reminders", []) if "id" in r}
        for rid, slot in list_state.items():
            if rid in seen_ids:
                continue
            fn = slot.get("fn") or reminder_filename(rid)
            if delete_item(sess, col_url + quote(fn)):
                deleted += 1
            else:
                errors += 1

        new_manifest[list_id] = new_list_state
        hb("OK", event="list_done", idx=li, list_name=list_name,
           pushed=list_pushed, changed=list_changed, skipped=list_skipped,
           errors=list_errors,
           total=len(lst.get("reminders", [])),
           elapsed_s=int(time.time() - list_t0))

    save_manifest(new_manifest)
    elapsed = int(time.time() - start)
    if pushed + changed + deleted == 0:
        hb("OK", event="idle", elapsed=f"{elapsed}s",
           lists=list_count, reminders=reminder_count, errors=errors)
    else:
        hb("OK", event="synced", elapsed=f"{elapsed}s",
           lists=list_count, reminders=reminder_count,
           pushed=pushed, changed=changed, deleted=deleted, errors=errors)


def main():
    try:
        sync()
        sys.exit(0)
    except Exception as ex:
        hb("FAIL", event="failed", exception=f"{type(ex).__name__}:{str(ex)[:200]}")
        sys.exit(1)


if __name__ == "__main__":
    main()

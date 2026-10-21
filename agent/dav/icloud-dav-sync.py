#!/usr/bin/python3
"""
icloud-dav-sync.py — Phase 5 sync, one-way iCloud → Nextcloud.

Replaces the previous vdirsyncer two-pair pipeline that was inadvertently
bidirectional and pushed sed-sanitized event content back to iCloud.

Design:
  - iCloud is accessed via a `ReadOnlySession` that REFUSES PUT/POST/DELETE/
    PROPPATCH/MOVE/COPY/MKCALENDAR/MKCOL — even buggy code cannot write
    to iCloud. Any attempt raises RuntimeError.
  - Sanitisation (strip ENCODING=*, empty URL;VALUE=URI:) happens in memory
    on the bytes between GET (iCloud) and PUT (Nextcloud). No on-disk staging.
  - Per-item etag state tracked in /var/lib/icloud-dav-sync/state.json so
    incremental cron runs only fetch+upload genuinely-changed items.
  - First run with empty state seeds state from existing iCloud etags WITHOUT
    pushing (assume Nextcloud is already in sync from earlier runs). Use
    --full-resync to force a full re-upload.

Heartbeats via syslog tag `icloud-dav-sync`:
  OK event=started
  OK event=synced  elapsed=Ns pushed=N changed=N deleted=N errors=N sanitized=N
  OK event=idle    elapsed=Ns pushed=0 changed=0 deleted=0 errors=N
  FAIL event=failed elapsed=Ns exception=Type:msg

Promtail picks up via syslog under {job="syslog", host="integr8", unit="icloud-dav-sync"}.

See applications/icloud-dav-sync/README.md for architecture + ops notes.
"""

import os
import re
import sys
import json
import time
import syslog
from pathlib import Path
from urllib.parse import urlparse, urljoin
from xml.etree import ElementTree as ET

import requests
from requests.auth import HTTPBasicAuth


# ---------- Config ----------
ENV_FILE = "/etc/icloud-dav/env"
STATE_DIR = Path("/var/lib/icloud-dav-sync")
STATE_FILE = STATE_DIR / "state.json"

ICLOUD_CALDAV_BASE = "https://caldav.icloud.com"
ICLOUD_CARDDAV_BASE = "https://contacts.icloud.com"
NEXTCLOUD_HOST = "https://nextcloud.example.com"

# Calendars synced (filtered to >0 events in last 90 days as of 2026-05-06)
CAL_FILTER = [
    ("3F62A660-95C1-490A-8B95-9630D51F3740", "iCloud — Calendar"),
    ("4DC46BE8-B2D1-4DAA-A41C-F0597C46F3B2", "iCloud — Work Calendar"),
    ("0d7fbc92-7a0e-47b2-a03e-48b7f75f8ed3", "iCloud — Family"),
]

ADDRBOOK_FILTER = [
    ("card", "iCloud — Contacts"),
]

# Reminders Lists (VTODO collections) are discovered DYNAMICALLY at each
# run — no hardcoded list. iCloud serves them from the same calendar-home
# as VEVENT calendars but with `<cal:supported-calendar-component-set>`
# set to VTODO instead of VEVENT. Each collection maps 1:1 to a Nextcloud
# task-only calendar with display name `iCloud — <listname>` (auto-created
# via MKCALENDAR if missing). Dynamic discovery means any new list created
# on the iCloud side (or shared with this account) flows in automatically
# on the next */5 cron firing — important for sovereignty backup, where
# we want to capture *every* list even those with zero pending tasks
# (CalDAV returns completed VTODOs alongside pending ones).

# ---------- DAV namespaces ----------
NS = {
    "d": "DAV:",
    "cal": "urn:ietf:params:xml:ns:caldav",
    "card": "urn:ietf:params:xml:ns:carddav",
}

# ---------- Sanitisation patterns ----------
# Strip Apple-side iCalendar quirks Nextcloud Sabre rejects with HTTP 415.
ENCODING_PARAM_RE = re.compile(rb";ENCODING=[^;:]*")
EMPTY_URL_RE = re.compile(rb"(?m)^URL;VALUE=URI:\r?\n")
# DTSTART line within a VTODO. iCloud's older Reminders exports often
# pair DTSTART with DUE in ways that violate strict iCalendar validation:
#   - DTSTART:T000000 (DATE-TIME, floating TZ) paired with
#     DUE;TZID=Australia/Brisbane:T131400 (different TZ → DUE-before-DTSTART)
#   - DTSTART:20100708T000000 (DATE-TIME) paired with
#     DUE;VALUE=DATE:20100708 (DATE — value-type mismatch)
# DTSTART on a task is rarely operationally meaningful; DUE is what matters.
# Strip DTSTART from VTODOs that also have a DUE — the conflict goes away
# and we lose no information any UI actually surfaces for tasks.
DTSTART_LINE_RE = re.compile(rb"(?m)^DTSTART[^\r\n]*\r?\n")


def sanitize(raw):
    out = ENCODING_PARAM_RE.sub(b"", raw)
    out = EMPTY_URL_RE.sub(b"", out)
    # VTODO-specific: strip DTSTART when DUE is also present.
    if b"BEGIN:VTODO" in out and re.search(rb"(?m)^DUE[:;]", out):
        out = DTSTART_LINE_RE.sub(b"", out)
    return out


# ---------- Sessions ----------
class ReadOnlySession:
    """A wrapper around requests.Session that REFUSES any write method.

    This is the security boundary that guarantees iCloud is never modified
    by this script — even if downstream code has a bug. Adding a new write
    method here requires a deliberate edit AND review.
    """

    WRITE_METHODS = frozenset({
        "PUT", "POST", "DELETE", "PROPPATCH",
        "MOVE", "COPY", "MKCALENDAR", "MKCOL",
    })

    def __init__(self, username, password, ua_label):
        self._s = requests.Session()
        self._s.auth = HTTPBasicAuth(username, password)
        self._s.headers["User-Agent"] = f"icloud-dav-sync/1.0 ({ua_label})"

    def request(self, method, url, **kw):
        if method.upper() in self.WRITE_METHODS:
            raise RuntimeError(
                f"REFUSED: {method} {url} — ReadOnlySession does not allow writes"
            )
        kw.setdefault("timeout", 60)
        return self._s.request(method, url, **kw)


class WriteSession:
    """Normal requests session for the Nextcloud (write-allowed) side."""

    def __init__(self, username, password, ua_label):
        self._s = requests.Session()
        self._s.auth = HTTPBasicAuth(username, password)
        self._s.headers["User-Agent"] = f"icloud-dav-sync/1.0 ({ua_label})"

    def request(self, method, url, **kw):
        kw.setdefault("timeout", 60)
        return self._s.request(method, url, **kw)


# ---------- Discovery ----------
def discover_principal(session, base_url):
    """PROPFIND <base>/  for current-user-principal."""
    body = (
        '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:current-user-principal/></d:prop>'
        '</d:propfind>'
    )
    r = session.request(
        "PROPFIND", base_url + "/", data=body, headers={"Depth": "0"}
    )
    r.raise_for_status()
    root = ET.fromstring(r.content)
    href_el = root.find(".//d:current-user-principal/d:href", NS)
    if href_el is None or not href_el.text:
        raise RuntimeError(f"no current-user-principal in PROPFIND of {base_url}")
    return _absolutise(href_el.text, base_url)


def discover_calendar_home(session, principal_url):
    body = (
        '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><cal:calendar-home-set/></d:prop>'
        '</d:propfind>'
    )
    r = session.request(
        "PROPFIND", principal_url, data=body, headers={"Depth": "0"}
    )
    r.raise_for_status()
    root = ET.fromstring(r.content)
    href_el = root.find(".//cal:calendar-home-set/d:href", NS)
    if href_el is None or not href_el.text:
        raise RuntimeError(f"no calendar-home-set on {principal_url}")
    return _absolutise(href_el.text, principal_url)


def discover_addressbook_home(session, principal_url):
    body = (
        '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">'
        '<d:prop><card:addressbook-home-set/></d:prop>'
        '</d:propfind>'
    )
    r = session.request(
        "PROPFIND", principal_url, data=body, headers={"Depth": "0"}
    )
    r.raise_for_status()
    root = ET.fromstring(r.content)
    href_el = root.find(".//card:addressbook-home-set/d:href", NS)
    if href_el is None or not href_el.text:
        raise RuntimeError(f"no addressbook-home-set on {principal_url}")
    return _absolutise(href_el.text, principal_url)


def _absolutise(href, ref_url):
    if href.startswith("http://") or href.startswith("https://"):
        return href
    p = urlparse(ref_url)
    return f"{p.scheme}://{p.netloc}{href}"


def discover_vtodo_collections(session, calendar_home_url):
    """Enumerate VTODO calendar collections under the calendar-home.

    Returns a list of (uuid, displayname) tuples for collections whose
    supported-calendar-component-set includes VTODO. Used for dynamic
    Reminders-list discovery so newly-created iCloud lists flow into
    Nextcloud automatically without script edits.
    """
    body = (
        '<?xml version="1.0" ?>'
        '<d:propfind xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">'
        '<d:prop>'
        '<d:displayname/>'
        '<d:resourcetype/>'
        '<cal:supported-calendar-component-set/>'
        '</d:prop>'
        '</d:propfind>'
    )
    r = session.request(
        "PROPFIND", calendar_home_url, data=body, headers={"Depth": "1"}
    )
    r.raise_for_status()
    root = ET.fromstring(r.content)
    out = []
    for resp in root.findall("d:response", NS):
        href_el = resp.find("d:href", NS)
        name_el = resp.find(".//d:displayname", NS)
        rt_cal = resp.find(".//d:resourcetype/cal:calendar", NS)
        if rt_cal is None:
            continue  # not a calendar collection (could be the home itself)
        comps = {
            c.get("name")
            for c in resp.findall(
                ".//cal:supported-calendar-component-set/cal:comp", NS
            )
        }
        if "VTODO" not in comps:
            continue
        if href_el is None or not href_el.text:
            continue
        # iCloud may return an absolute URL or a path-only href; collection
        # UUID is the last non-empty path segment.
        uuid = href_el.text.rstrip("/").rsplit("/", 1)[-1]
        name = name_el.text if (name_el is not None and name_el.text) else uuid
        out.append((uuid, name))
    return out


# ---------- Item listing ----------
def list_collection_etags(session, collection_url, item_ext):
    """PROPFIND depth 1 to list {href: etag} for items in a collection.

    item_ext is ".ics" or ".vcf" — used to filter out the collection itself
    and any sub-collections from the response.
    """
    body = (
        '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:getetag/></d:prop>'
        '</d:propfind>'
    )
    r = session.request(
        "PROPFIND", collection_url, data=body, headers={"Depth": "1"}
    )
    r.raise_for_status()
    root = ET.fromstring(r.content)
    out = {}
    for resp in root.findall("d:response", NS):
        href_el = resp.find("d:href", NS)
        etag_el = resp.find(".//d:getetag", NS)
        if href_el is None or not href_el.text:
            continue
        href = href_el.text
        if not href.lower().endswith(item_ext):
            continue
        if etag_el is None or not etag_el.text:
            continue
        out[href] = etag_el.text.strip('"')
    return out


def get_item(session, ref_url, href):
    url = _absolutise(href, ref_url)
    r = session.request("GET", url)
    r.raise_for_status()
    return r.content


def put_item(session, url, data, content_type):
    r = session.request(
        "PUT", url,
        data=data,
        headers={"Content-Type": content_type},
    )
    if r.status_code in (200, 201, 204):
        return r.headers.get("ETag", "").strip('"')
    return None


def delete_item(session, url):
    r = session.request("DELETE", url)
    return r.status_code in (200, 204, 404)


def mkcalendar_if_missing(session, url, display_name, components):
    """Create a Nextcloud calendar collection if it doesn't already exist.

    components: tuple of strings, e.g. ("VTODO",) for task-only or ("VEVENT",)
    for event-only. Sabre/Nextcloud honours the supported-calendar-component-
    set extended property and constrains the collection accordingly.

    Returns: "exists" if pre-existing, "created" if just MKCALENDAR'd,
             False on hard failure. Caller can use the distinction to force
             a full push for newly-created collections (which are guaranteed
             empty on the Nextcloud side).

    The PROPFIND probe before MKCALENDAR avoids a noisy "already exists" 405
    response in the common steady-state case.
    """
    # Probe: depth 0 PROPFIND. 200/207 = exists, 404 = doesn't exist.
    probe_body = (
        '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:resourcetype/></d:prop>'
        '</d:propfind>'
    )
    r = session.request("PROPFIND", url, data=probe_body, headers={"Depth": "0"})
    if r.status_code in (200, 207):
        return "exists"
    if r.status_code != 404:
        return False  # unexpected — surface as an error

    comp_xml = "".join(f'<cal:comp name="{c}"/>' for c in components)
    # body is built as Python str then explicitly UTF-8 encoded before
    # send. Without .encode("utf-8"), requests falls back to ISO-8859-1
    # for str payloads and corrupts non-Latin-1 characters (e.g. em-dash
    # U+2014 in our display names). Sabre then rejects with 400 BadRequest
    # 'expected >' at the byte-position the corruption landed.
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<cal:mkcalendar xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">'
        '<d:set><d:prop>'
        f'<d:displayname>{display_name}</d:displayname>'
        f'<cal:supported-calendar-component-set>{comp_xml}</cal:supported-calendar-component-set>'
        '</d:prop></d:set>'
        '</cal:mkcalendar>'
    ).encode("utf-8")
    r = session.request(
        "MKCALENDAR", url,
        data=body,
        headers={"Content-Type": "application/xml; charset=utf-8"},
    )
    if r.status_code in (201, 207):
        return "created"
    return False


# ---------- Sync core ----------
def sync_collection(
    icloud_session, nc_session,
    icloud_url, nc_url,
    state, content_type, item_ext,
    full_resync=False,
):
    """One-way sync from one iCloud collection to one Nextcloud collection.

    state: dict {icloud_href: [icloud_etag, nc_filename]}  (read+mutated)

    Returns counts: (pushed_new, changed, deleted, errors, sanitized)
    """
    pushed = changed = deleted = errors = sanitized = 0

    icloud_items = list_collection_etags(icloud_session, icloud_url, item_ext)

    new_state = {}
    seed_only = (not state) and not full_resync  # first run: just record etags

    for ic_href, ic_etag in icloud_items.items():
        prior = state.get(ic_href)
        nc_filename = ic_href.rsplit("/", 1)[-1]
        nc_item_url = nc_url + nc_filename

        if seed_only:
            # Empty state + not forced: don't push, just record what's there
            new_state[ic_href] = [ic_etag, nc_filename]
            continue

        if prior and prior[0] == ic_etag:
            # Unchanged
            new_state[ic_href] = prior
            continue

        # New or changed: GET full content from iCloud, sanitize, PUT to Nextcloud
        try:
            raw = get_item(icloud_session, icloud_url, ic_href)
            cleaned = sanitize(raw)
            if cleaned != raw:
                sanitized += 1
            new_etag = put_item(nc_session, nc_item_url, cleaned, content_type)
            if new_etag is None:
                errors += 1
                continue
            new_state[ic_href] = [ic_etag, nc_filename]
            if prior is None:
                pushed += 1
            else:
                changed += 1
        except Exception:
            errors += 1
            # Keep prior state so a transient failure doesn't lose tracking
            if prior is not None:
                new_state[ic_href] = prior

    # Detect deletions: items in prior state but no longer on iCloud.
    # Skip during seed_only run (since "empty state" means we don't have history).
    if not seed_only:
        for ic_href, slot in state.items():
            if ic_href in icloud_items:
                continue
            try:
                _, nc_filename = slot[0], slot[1]
                if delete_item(nc_session, nc_url + nc_filename):
                    deleted += 1
                else:
                    errors += 1
            except Exception:
                errors += 1

    return new_state, pushed, changed, deleted, errors, sanitized


# ---------- Helpers ----------
def load_env():
    env = {}
    for line in Path(ENV_FILE).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        env[k] = v
    required = [
        "APPLE_ID_USERNAME", "APPLE_ID_APP_PASSWORD",
        "NEXTCLOUD_USERNAME", "NEXTCLOUD_APP_PASSWORD",
    ]
    missing = [k for k in required if k not in env]
    if missing:
        raise RuntimeError(f"missing env keys: {missing}")
    return env


def emit(level, **kvs):
    syslog.openlog("icloud-dav-sync", syslog.LOG_PID, syslog.LOG_USER)
    parts = [level] + [f"{k}={v}" for k, v in kvs.items()]
    msg = " ".join(parts)
    syslog.syslog(syslog.LOG_INFO, msg)
    syslog.closelog()


def load_state():
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(STATE_FILE)


# ---------- Entry point ----------
def main():
    start = time.time()
    full_resync = "--full-resync" in sys.argv
    emit("OK", **{"event": "started", "mode": "full-resync" if full_resync else "incremental"})

    try:
        env = load_env()
        state = load_state()

        # iCloud — READ-ONLY (security boundary)
        ic_cal_sess = ReadOnlySession(
            env["APPLE_ID_USERNAME"], env["APPLE_ID_APP_PASSWORD"],
            "icloud-caldav-readonly",
        )
        ic_card_sess = ReadOnlySession(
            env["APPLE_ID_USERNAME"], env["APPLE_ID_APP_PASSWORD"],
            "icloud-carddav-readonly",
        )

        # Nextcloud — read+write
        nc_sess = WriteSession(
            env["NEXTCLOUD_USERNAME"], env["NEXTCLOUD_APP_PASSWORD"],
            "nextcloud-caldav-rw",
        )

        # Discover iCloud principal + collection homes
        ic_cal_principal = discover_principal(ic_cal_sess, ICLOUD_CALDAV_BASE)
        ic_cal_home = discover_calendar_home(ic_cal_sess, ic_cal_principal)
        ic_card_principal = discover_principal(ic_card_sess, ICLOUD_CARDDAV_BASE)
        ic_card_home = discover_addressbook_home(ic_card_sess, ic_card_principal)

        nc_user = env["NEXTCLOUD_USERNAME"]
        nc_cal_base = f"{NEXTCLOUD_HOST}/remote.php/dav/calendars/{nc_user}/"
        nc_card_base = f"{NEXTCLOUD_HOST}/remote.php/dav/addressbooks/users/{nc_user}/"

        # Per-source stats so the dashboard can split Calendars / Contacts /
        # Tasks (Reminders) cleanly.
        cal_pushed = cal_changed = cal_deleted = cal_errors = cal_sanitized = 0
        con_pushed = con_changed = con_deleted = con_errors = con_sanitized = 0
        tas_pushed = tas_changed = tas_deleted = tas_errors = tas_sanitized = 0

        # Calendars
        for col_id, _displayname in CAL_FILTER:
            ic_url = f"{ic_cal_home}{col_id}/"
            nc_url = f"{nc_cal_base}{col_id}/"
            key = f"cal/{col_id}"
            col_state = state.get(key, {})
            new_state, p, c, d, e, s = sync_collection(
                ic_cal_sess, nc_sess, ic_url, nc_url,
                col_state, "text/calendar; charset=utf-8", ".ics",
                full_resync=full_resync,
            )
            state[key] = new_state
            cal_pushed += p
            cal_changed += c
            cal_deleted += d
            cal_errors += e
            cal_sanitized += s

        # Address books
        for ab_id, _displayname in ADDRBOOK_FILTER:
            ic_url = f"{ic_card_home}{ab_id}/"
            nc_url = f"{nc_card_base}{ab_id}/"
            key = f"card/{ab_id}"
            col_state = state.get(key, {})
            new_state, p, c, d, e, s = sync_collection(
                ic_card_sess, nc_sess, ic_url, nc_url,
                col_state, "text/vcard; charset=utf-8", ".vcf",
                full_resync=full_resync,
            )
            state[key] = new_state
            con_pushed += p
            con_changed += c
            con_deleted += d
            con_errors += e
            con_sanitized += s

        # Reminders Lists (VTODO collections). iCloud serves these from the
        # same calendar-home as VEVENT calendars; we MKCALENDAR a VTODO-only
        # collection on the Nextcloud side. Nextcloud URL uses a `tasks-`
        # prefix so:
        #   - the path is clearly distinct from VEVENT calendar paths in the
        #     Nextcloud DAV namespace
        #   - it never collides with a calendar (or trashed-calendar entry)
        #     at the same UUID. Sabre keeps deleted calendars in trash and
        #     refuses MKCALENDAR at a path matching a trashed entry with
        #     405 'already exists', which would jam new VTODO collections.
        # The iCloud-side URL stays the bare UUID — that's what Apple serves.
        # Dynamic discovery — re-enumerate VTODO collections every run so
        # new iCloud Reminders Lists flow in automatically without code edits.
        discovered_tasks = discover_vtodo_collections(ic_cal_sess, ic_cal_home)
        for col_id, source_name in discovered_tasks:
            ic_url = f"{ic_cal_home}{col_id}/"
            nc_url = f"{nc_cal_base}tasks-{col_id}/"
            displayname = f"iCloud — {source_name}"
            mk_result = mkcalendar_if_missing(nc_sess, nc_url, displayname, ("VTODO",))
            if not mk_result:
                tas_errors += 1
                continue
            key = f"tas/{col_id}"
            col_state = state.get(key, {})
            # Tasks are a new feature (rolled out 2026-05-07). Unlike Phase 5
            # which assumed Nextcloud was pre-populated by manual bulk sync,
            # task collections are MKCALENDAR'd on the Nextcloud side empty
            # and rely on the script to push everything. Force full_resync
            # for the tasks loop. Steady-state cost is one PROPFIND per
            # collection per run; only changed items actually get pushed
            # because unchanged-etag items short-circuit inside sync_collection.
            new_state, p, c, d, e, s = sync_collection(
                ic_cal_sess, nc_sess, ic_url, nc_url,
                col_state, "text/calendar; charset=utf-8", ".ics",
                full_resync=True,
            )
            state[key] = new_state
            tas_pushed += p
            tas_changed += c
            tas_deleted += d
            tas_errors += e
            tas_sanitized += s

        save_state(state)
        elapsed = int(time.time() - start)

        total_activity = (
            cal_pushed + cal_changed + cal_deleted
            + con_pushed + con_changed + con_deleted
            + tas_pushed + tas_changed + tas_deleted
        )
        total_errors = cal_errors + con_errors + tas_errors
        total_sanitized = cal_sanitized + con_sanitized + tas_sanitized

        # Common per-source kvs — included in BOTH idle and synced heartbeats
        # so the dashboard can extract them with a single regex per panel
        # regardless of which event variant landed.
        per_source_kvs = {
            "cal_pushed": cal_pushed, "cal_changed": cal_changed,
            "cal_deleted": cal_deleted, "cal_errors": cal_errors,
            "cal_sanitized": cal_sanitized,
            "con_pushed": con_pushed, "con_changed": con_changed,
            "con_deleted": con_deleted, "con_errors": con_errors,
            "con_sanitized": con_sanitized,
            "tas_pushed": tas_pushed, "tas_changed": tas_changed,
            "tas_deleted": tas_deleted, "tas_errors": tas_errors,
            "tas_sanitized": tas_sanitized,
        }

        if total_activity == 0:
            emit("OK",
                 event="idle", elapsed=f"{elapsed}s",
                 pushed=0, changed=0, deleted=0,
                 errors=total_errors,
                 **per_source_kvs)
        else:
            emit("OK",
                 event="synced", elapsed=f"{elapsed}s",
                 pushed=cal_pushed + con_pushed + tas_pushed,
                 changed=cal_changed + con_changed + tas_changed,
                 deleted=cal_deleted + con_deleted + tas_deleted,
                 errors=total_errors,
                 sanitized=total_sanitized,
                 **per_source_kvs)
        sys.exit(0)

    except Exception as ex:
        elapsed = int(time.time() - start)
        emit("FAIL",
             event="failed", elapsed=f"{elapsed}s",
             exception=f"{type(ex).__name__}:{str(ex)[:160]}")
        sys.exit(1)


if __name__ == "__main__":
    main()

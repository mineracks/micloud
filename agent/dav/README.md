# icloud-dav-sync — iCloud Calendars + Contacts → Nextcloud

One-way sync of iCloud calendars + contacts to Nextcloud (Phase 5 of the
[icloud-sovereign-backup roadmap](../../roadmap/_completed/icloud-sovereign-backup/README.md)).

Runs on `integr8` (`mineracks-vm-n8n`, Tailscale `TAILNET_HOST`) every 5 min via
root cron. iCloud is the read-only source of truth; Nextcloud is the sovereign mirror.

## Architecture (and why it's NOT vdirsyncer)

The first design used a vdirsyncer two-pair pipeline (iCloud→filesystem→sanitize→Nextcloud).
That design failed disastrously: the sed-sanitize step modified staged files, vdirsyncer's
bidirectional sync detected the diffs, and pushed sed-cleaned content **back to iCloud** —
~3,000 events on iCloud were silently overwritten before we caught it. vdirsyncer 0.19
has no real one-way mode.

Current design — single-process Python script using raw HTTP:

```
iCloud (CalDAV/CardDAV)                    Nextcloud Calendar/Contacts
   │                                              ▲
   │  (1) PROPFIND depth=1 — list etags          │
   │  (2) GET — fetch only changed items         │  (4) PUT cleaned bytes
   ▼                                              │  (5) DELETE removed items
ReadOnlySession  ──────►  sanitize() in memory  ─►  WriteSession
(refuses PUT/POST/DELETE/                          (full read+write)
 PROPPATCH/MOVE/COPY/
 MKCALENDAR/MKCOL)
```

Key safety property: the iCloud `requests.Session` is wrapped in `ReadOnlySession`,
which raises `RuntimeError` on any write method. Even a buggy code path that tries
to PUT to iCloud will fail loudly. This is the single architectural guarantee that
makes the sync genuinely one-way.

## Deliverables

| Path on integr8 | Mode | Purpose |
|---|---|---|
| `/usr/local/bin/icloud-dav-sync.py` | 755 root | The sync script. Single Python file, ~330 lines. |
| `/etc/icloud-dav/env` | 600 root | iCloud + Nextcloud creds (sourced as env vars by the script). |
| `/var/lib/icloud-dav-sync/state.json` | 600 root | Per-item `{icloud_href: [etag, nc_filename]}` for incremental sync. |
| `/var/run/icloud-dav-sync.lock` | n/a | flock anchor — auto-cleared on process exit. |
| `/var/log/icloud-dav-sync.log` | 600 root | stdout/stderr from cron (mostly empty — script writes via syslog). |
| Root crontab line | n/a | `*/5 * * * * /usr/bin/flock -n /var/run/icloud-dav-sync.lock /usr/local/bin/icloud-dav-sync.py >> /var/log/icloud-dav-sync.log 2>&1` |

The repo source-of-truth for the script is
[`applications/icloud-dav-sync/icloud-dav-sync.py`](icloud-dav-sync.py).

## What syncs

**Calendars** — filtered to the 3 with >0 events in the last 90 days (data-driven on 2026-05-06):

| iCloud collection ID | Display name on Nextcloud | Initial event count |
|---|---|---|
| `CALENDAR-UUID` | iCloud — Calendar | 1417 |
| `CALENDAR-UUID` | iCloud — Work Calendar | 3423 |
| `0d7fbc92-7a0e-47b2-a03e-48b7f75f8ed3` | iCloud — Family | 3271 |

13 other iCloud calendars had 0 events in the last 90 days and are deliberately
not in `CAL_FILTER` (in the script). Re-evaluate the filter if any become active.

**Contacts** — the single iCloud address book `card` → Nextcloud addressbook `card`
("iCloud — Contacts" displayname), 2965 contacts. iCloud groups preserved as VCard
`CATEGORIES` and surface as groups in Nextcloud Contacts UI.

**Total**: ~11,076 items mirrored on first sync.

## Sanitisation

Two sed-style patterns applied **in memory** (in the bytes between iCloud GET and
Nextcloud PUT — never written to disk in modified form):

1. **`;ENCODING=<anything>`** parameter on text properties. Apple-side legacy from
   vCalendar 1.0 / Outlook-era exports. Sabre rejects with HTTP 415: `ENCODING=...
   is not valid for this document type`. Pattern: `s/;ENCODING=[^;:]*//g`.
   Examples seen: `LOCATION;ENCODING=QUOTED-PRINTABLE:Elite Pro Therapy` (Mindbody
   booking events, ~2400 in initial data), `SUMMARY;ENCODING=UTF-8:Pax8 Virtual...`.

2. **Empty `URL;VALUE=URI:`** lines. Apple iPhone OS exports many events with a
   literal empty URL property. Sabre rejects with `Parse error: Invalid Mimedir
   file. Line starting at N did not follow iCalendar/vCard conventions`. Pattern:
   `/^URL;VALUE=URI:$/d`.

A third class of rejection — malformed multi-line `X-APPLE-STRUCTURED-LOCATION`
(Apple iPhone OS 26 line-folding bug) — affects ~2 events. These cannot be fixed
without a real iCalendar parser. They show as `errors=N` in the heartbeat and are
the steady-state floor. Don't try to "fix" them with a parser-rewrite step —
that's exactly what caused the 2026-05-06 reverse-sync incident; any on-disk
post-pull modification cycles back into a re-upload.

## Loki heartbeats

The script emits one syslog line per phase via tag `icloud-dav-sync`:

```
OK event=started mode=incremental
OK event=synced  elapsed=Ns pushed=N changed=N deleted=N errors=N sanitized=N cal_pushed=N cal_changed=N cal_deleted=N cal_errors=N cal_sanitized=N con_pushed=N con_changed=N con_deleted=N con_errors=N con_sanitized=N
OK event=idle    elapsed=Ns pushed=0 changed=0 deleted=0 errors=N cal_pushed=0 cal_changed=0 cal_deleted=0 cal_errors=N cal_sanitized=0 con_pushed=0 con_changed=0 con_deleted=0 con_errors=N con_sanitized=0
FAIL event=failed elapsed=Ns exception=Type:msg
```

The `cal_*` and `con_*` fields are per-source counters (Calendars vs Contacts)
emitted in every heartbeat — the Grafana dashboard splits them into separate
rows by extracting these fields with a `regexp` stage. The unprefixed
`pushed/changed/deleted/errors` fields are the rolled-up totals and are kept
for backwards compatibility with the existing `icloud-dav-sync-stale` alert.

These hit Loki via Promtail's syslog scrape under
`{job="syslog", host="n8n", unit="icloud-dav-sync"}` — note `host="n8n"`,
not `host="integr8"`. Promtail's host label uses the inventory name, not
`/etc/hostname`. Same labelling scheme as the established `sentinel-synthetic-*`
and `*-self-heal` heartbeats.

Sentinel alert rule (file-provisioned via `applications/icloud-sync/alerting.yml`):
- UID: `icloud-dav-sync-stale`
- Query: `(sum(count_over_time({job="syslog", host="n8n", unit="icloud-dav-sync"} |~ "event=(synced|idle)" [30m]))) or vector(0) < 1`
- Fires when no `synced` or `idle` event in 30 min.

## State file mechanics

`state.json` is a flat map keyed by `cal/<collection-id>` or `card/<book-id>`. Each
value is itself a map of `{icloud_href: [icloud_etag, nextcloud_filename]}`.

- **First run with empty state** ("seed-only" mode): list current iCloud etags
  and write them to state. **No PUT to Nextcloud.** This avoids re-uploading
  thousands of items just to populate state. Assumption: Nextcloud already
  reflects iCloud closely enough (e.g. previous successful runs).
- **Subsequent runs** ("incremental" mode):
  - For each iCloud item: if etag matches state → skip. Else → GET from iCloud,
    sanitize, PUT to Nextcloud, update state.
  - For each item in state but no longer in iCloud → DELETE from Nextcloud.
- **Forced full re-sync**: run `icloud-dav-sync.py --full-resync` to bypass the
  seed-only short-circuit and PUT every item to Nextcloud (slow — ~25 min for
  ~11k items).

## Operational recipes

### Verify a sync finished cleanly

```bash
ssh n8n "sudo journalctl -t icloud-dav-sync -n 5 --no-pager"
# Look for: OK event=synced ... or OK event=idle ...
```

### Force a full re-sync (re-upload everything to Nextcloud)

```bash
ssh n8n
sudo /usr/local/bin/icloud-dav-sync.py --full-resync
```

### Add a calendar to the filter

Edit `CAL_FILTER` in `/usr/local/bin/icloud-dav-sync.py` to include the new
iCloud collection-id + a display name. The script will discover it on next run
and create the corresponding Nextcloud calendar via the first PUT (Nextcloud
auto-creates calendar collections on first event PUT to a new path... actually
no, you'd need to create the Nextcloud collection manually first via PROPPATCH
or the Calendar UI).

### Reset state (forget everything, start over)

```bash
ssh n8n
sudo rm /var/lib/icloud-dav-sync/state.json
sudo /usr/local/bin/icloud-dav-sync.py            # re-seeds (no writes)
sudo /usr/local/bin/icloud-dav-sync.py --full-resync   # if you ALSO want to re-upload to Nextcloud
```

### Rotate the Apple app-specific password

1. Generate new app password at appleid.apple.com → labelled `mineracks-dav-integr8-vN`
2. Store in vault as `vault_apple_id_app_password_dav` (replacing the old value)
3. `sudo $EDITOR /etc/icloud-dav/env`  → update `APPLE_ID_APP_PASSWORD`
4. Test: `sudo /usr/local/bin/icloud-dav-sync.py`
5. Revoke old app password at appleid.apple.com

### Rotate the Nextcloud app token

1. Generate new token at nextcloud.example.com → Settings → Security → "Devices & sessions"
2. Store in vault as `vault_nextcloud_alice_app_password_dav`
3. `sudo $EDITOR /etc/icloud-dav/env`  → update `NEXTCLOUD_APP_PASSWORD`
4. Test: `sudo /usr/local/bin/icloud-dav-sync.py`
5. Revoke old token from same Nextcloud Security page

## What lives in vault

| Key | Purpose |
|---|---|
| `vault_apple_id_username` | Apple ID email for CalDAV/CardDAV auth |
| `vault_apple_id_app_password_dav` | App-specific password (covers both DAV protocols) |
| `vault_nextcloud_alice_app_password_dav` | Nextcloud app token for `you@example.com` |

These are sourced into `/etc/icloud-dav/env` — never inline in cron.

## Verifying from a device

- **Web (cleanest, no install):** open `https://nextcloud.example.com/apps/calendar/` —
  the 3 iCloud calendars appear in the sidebar with iCloud-prefixed names,
  individually toggleable. Same for `/apps/contacts/`.
- **iOS (native, isolated from iCloud):** Settings → Calendar → Add Account →
  Other → CalDAV; server `nextcloud.example.com`, user
  `you@example.com`, password = a fresh Nextcloud app token. Same
  flow under Settings → Contacts → Add Account → CardDAV. Use a per-device app
  token so it can be revoked independently.
- **iOS Nextcloud Files app does NOT show calendars/contacts** — files only.

## Subscribed calendars to add manually in Nextcloud (one-time)

iCloud "Subscribed" calendars (Holidays AU, third-party ICS feeds) are URL
subscriptions on the Apple side and not exposed via CalDAV. They will never
come across via this sync. To mirror them, add them as native subscriptions in
Nextcloud Calendar → "+ New subscription" → paste the public ICS URL. Examples
to look for in Apple Calendar.app on the Mac:

- Holidays AU
- Any third-party event-source calendars (sport schedules, conference agendas)

## Why we ended up with the current design (post-mortem of 2026-05-06)

Three failed attempts before the working version. Worth recording so future-me
doesn't repeat them:

1. **vdirsyncer single-pair iCloud → Nextcloud direct.** Failed at HTTP 415
   on every event due to `ENCODING=QUOTED-PRINTABLE` and empty `URL;VALUE=URI:`
   in the iCloud-side iCalendar. Sabre is strict; iCloud is lenient.

2. **vdirsyncer two-pair: iCloud → filesystem → sanitize → Nextcloud.** The
   sanitize step (sed) mutated files between syncs. vdirsyncer's bidirectional
   sync interpreted "staging changed" as "push staging back to iCloud", and
   pushed ~3,000 sed-cleaned events back to iCloud over multiple cron cycles
   before we caught it. iCloud events still functional (the user verified
   Marilyn dinner location + Apple Maps tap survived) but content was modified
   without consent. vdirsyncer 0.19 has no real one-way mode.

3. **vdirsyncer two-pair + Python icalendar reserialize.** Same problem as (2),
   amplified — the reserializer rewrote ~300 files canonically, vdirsyncer
   pushed all 300 to iCloud. Killed mid-run.

4. **(Working) Single Python script, ReadOnlySession.** This is the only
   architecture where iCloud is provably never written to, regardless of bugs
   in downstream code. The wrapper is its own security boundary.

If you ever feel tempted to use vdirsyncer for a one-way pipeline, re-read this
post-mortem.

# iCloud Synchronisation

Monitoring + dashboards for the Mac Studio sync chain that backs up iCloud → mineracks self-hosted services.

## What's running where

The Mac Studio (Tailscale: `relay-mac`) hosts the following sync scripts driven by macOS launchd:

| Script | Schedule | Source → Destination | Tech |
|---|---|---|---|
| `~/bin/immich-photo-sync.sh` | hourly @ :00 + WatchPaths | iCloud Photos via `.photoslibrary` → Immich (photos VM) | `find` originals + manifest-diff → immich-cli upload (full library) |
| `~/bin/nextcloud-photo-sync.sh` | hourly @ :30 + WatchPaths | iCloud Photos via `.photoslibrary` (capture-date ≥ 2026-05-08) → Nextcloud `Photos/iCloud-Camera/{YYYY}/{YYYY-MM}/` (files VM) | osxphotos `--from-date --update` → rclone copy WebDAV. Phase 1.5 forward-only mirror. Source of truth: `scripts/nextcloud-photo-sync.sh` |
| `~/bin/icloud-drive-sync.sh` (drive-hourly) | hourly + WatchPaths | `~/Desktop` + `~/Library/Mobile Documents/com~apple~CloudDocs/` (excluding Documents) → Nextcloud (files VM) | rclone WebDAV |
| `~/bin/rclone-documents-sync.sh` (documents-15m) | every 15 min | `~/Documents` → Nextcloud | rclone WebDAV |
| `~/bin/imessage-mirror-sync.sh` (imessage-daily) | daily @ 05:17 | `~/Library/Messages/chat.db` (iMessage + SMS/MMS) → Nextcloud `Messages/iMessage/` (files VM) | online `.backup` → `imessage-exporter` HTML (`-c full`: HEIC→JPEG, MOV→MP4) → `rclone copy --checksum`. **Phase 8.1** append-only archive. Source of truth: `scripts/bin/imessage-mirror-sync.sh`. See [IMESSAGE-MIRROR.md](IMESSAGE-MIRROR.md) |

All emit Loki heartbeats (`started` / `idle` / `uploaded` / `failed` / `locked`) on every invocation, parsed into the Grafana dashboard and the stale-sync alerts.

## Where the artifacts live

| Artifact | This repo | On logs VM | Live in Grafana |
|---|---|---|---|
| Dashboard | `grafana-dashboard.json` | `/opt/loki-stack/dashboards/icloud-sync.json` | `https://grafana.example.com/d/immich-sync/icloud-synchronisation` (uid `immich-sync`) |
| Dashboards provider config | `grafana-dashboards-provider.yml` | `/opt/loki-stack/grafana-dashboards-provider.yml` | mounted at `/etc/grafana/provisioning/dashboards/mineracks.yml` |
| Alerts (live source) | `alerting.yml` | `/opt/loki-stack/alerting/icloud-sync.yml` | mounted at `/etc/grafana/provisioning/alerting/icloud-sync.yml` |
| Alerts (per-rule JSON snapshots) | `alerts/*.json` | n/a | useful for diffing single rules |
| Mac-Studio scripts (source of truth) | `scripts/*.sh`, `scripts/*.plist` | n/a — deploy with `scp` to `~/bin/` and `~/Library/LaunchAgents/` | n/a |

**The repo is now the source of truth.** As of 2026-05-03, Grafana on [`logs`](../../virtual-machines/logs/README.md) VM provisions both the dashboard and the 3 alert rules from files in `/opt/loki-stack/`. Rules show `provenance=file` in the API; the dashboard shows `meta.provisioned=True`. UI edits are read-only — to change anything, edit the file in this repo, push, and copy to `/opt/loki-stack/` (Grafana auto-reloads dashboards every 30s; alerting reload requires a Grafana restart with `docker compose up -d --force-recreate grafana`).

Sync from repo to logs VM is currently manual — see "Updating provisioned content" below.

## Loki heartbeat conventions

Every script pushes one or more Loki streams per run with these labels:

```
job=immich_sync                (Phase 1: Photos -> Immich)
job=nextcloud_photos_sync      (Phase 1.5: Photos -> Nextcloud, forward-only)
job=icloud_drive_sync          (both rclone Drive/Documents scripts)
job=imessage_mirror            (Phase 8.1: iMessage/SMS -> Nextcloud, append-only)
script=drive-hourly|documents-15m|imessage-daily   (distinguishes scripts sharing a job/host)
host=mac-studio
event=started|idle|uploaded|failed|locked|retrying|retry_ok|dryrun
```

Line content is human-readable English with structured trailing keyvals for LogQL parsing:

```
2026-05-03T03:53:55Z started  Sync started
2026-05-03T04:04:17Z idle     No changes detected (took 622s) added=0 changed=0 deleted=0
2026-05-03T...:...:..Z uploaded Sync complete: 3 added, 0 changed, 0 deleted (NNNs) — files: foo.txt, bar.heic, baz.png +N more added=N changed=N deleted=N
```

## Health stat semantics (dashboard's top-row big square)

The "Photos: health" / "Files: health" stat panels evaluate one of four states via a Math expression chain over Loki query results:

- **HEALTHY** (green): ≥1 successful run in the recent window AND zero failures in 24h
- **WARNING** (yellow): some success AND some failures in window
- **INVESTIGATE** (red): zero successes AND ≥1 failure
- **UNKNOWN** (grey): no data at all in the window (also covers the bootstrap case)

Photos uses a 3h success window (script fires hourly so 3h gives 3 firings of resilience). Files uses a 4h window (documents-15m runs serialise behind a 30-40 min execution time, so most timer fires bail with `locked`; 4h ensures at least 1 successful completion in the window).

## Updating provisioned content

After editing any file in this directory:

```bash
# Copy the changed file(s) to logs VM. Examples:
scp grafana-dashboard.json logs:/tmp/icloud-sync.json
ssh logs 'sudo cp /tmp/icloud-sync.json /opt/loki-stack/dashboards/icloud-sync.json'

scp alerting.yml logs:/tmp/alerting.yml
ssh logs 'sudo cp /tmp/alerting.yml /opt/loki-stack/alerting/icloud-sync.yml'

# Dashboard reloads automatically every 30s (per provider's updateIntervalSeconds)
# Alerting requires a Grafana restart:
ssh logs 'cd /opt/loki-stack && sudo docker compose up -d --force-recreate grafana'
```

After a Grafana restart, verify the alerts are still file-provisioned (not API):

```bash
ssh logs 'curl -s -u admin:<GRAFANA_PASSWORD> http://localhost:3000/api/v1/provisioning/alert-rules' \
  | jq -r '.[] | select(.uid|test("icloud|immich")) | "\(.uid)\t\(.provenance)"'
# Expect "file" for all three.
```

## Re-deploy from scratch (fresh logs VM / lost grafana-data)

```bash
# 1. Copy the artifacts onto logs VM
ssh logs 'sudo mkdir -p /opt/loki-stack/dashboards /opt/loki-stack/alerting && sudo chown mineracks /opt/loki-stack/dashboards /opt/loki-stack/alerting'
scp grafana-dashboard.json                logs:/opt/loki-stack/dashboards/icloud-sync.json
scp alerting.yml                          logs:/opt/loki-stack/alerting/icloud-sync.yml
scp grafana-dashboards-provider.yml       logs:/tmp/provider.yml && \
  ssh logs 'sudo mv /tmp/provider.yml /opt/loki-stack/grafana-dashboards-provider.yml && sudo chown root /opt/loki-stack/grafana-dashboards-provider.yml'

# 2. Update docker-compose.yml on logs VM to mount these into Grafana:
#    - ./grafana-dashboards-provider.yml:/etc/grafana/provisioning/dashboards/mineracks.yml:ro
#    - ./dashboards:/etc/grafana/dashboards:ro
#    - ./alerting:/etc/grafana/provisioning/alerting:ro
# (See `docker-compose.yml` snippet below.)

# 3. Recreate Grafana
ssh logs 'cd /opt/loki-stack && sudo docker compose up -d --force-recreate grafana'

# 4. Verify
ssh logs 'curl -s -u admin:<GRAFANA_PASSWORD> http://localhost:3000/api/dashboards/uid/immich-sync | jq .meta.provisioned'
# Expect: true
```

The Loki datasource UID `P8E80F9AEF21F6940` is hardcoded throughout the dashboard JSON; if the target Grafana has a different UID, search-replace before deploying.

### docker-compose.yml grafana service mount lines

```yaml
grafana:
  volumes:
    - grafana-data:/var/lib/grafana
    - ./grafana-datasources.yml:/etc/grafana/provisioning/datasources/ds.yml:ro
    - ./grafana-dashboards-provider.yml:/etc/grafana/provisioning/dashboards/mineracks.yml:ro
    - ./dashboards:/etc/grafana/dashboards:ro
    - ./alerting:/etc/grafana/provisioning/alerting:ro
```

## Migrating an API-provenance rule to file provisioning

If a rule was created via API (provenance=api) and you want to manage it via file, Grafana refuses to overwrite it (`cannot change provenance from 'api' to 'file'`). Workaround: delete the rule via API first, then file-provision it.

```bash
curl -s -u admin:<GRAFANA_PASSWORD> -X DELETE \
  http://logs:3000/api/v1/provisioning/alert-rules/{uid}
# Then restart Grafana so it re-creates the rule from the provisioning file.
ssh logs 'cd /opt/loki-stack && sudo docker compose up -d --force-recreate grafana'
```

If Grafana is in a startup crash-loop because of the provenance conflict, temporarily back out the alerting mount from docker-compose, restart Grafana, do the API delete, then re-add the mount. (Hit this on the initial 2026-05-03 conversion.)

## Known gotchas (lessons learnt during the build)

1. **macOS BSD mktemp template syntax** — `mktemp /tmp/foo-XXXXXX.log` does NOT expand on BSD mktemp because the X's aren't trailing. Use `mktemp /tmp/foo.XXXXXX` (X's at end) or `mktemp -t foo` instead. Bug from 2026-05-03 caused 36+ hours of `documents-15m` reporting failures because a stale literal file `/tmp/rclone-docs-run-XXXXXX.log` blocked every run.
2. **gawk-only `match($0, regex, array)` 3-arg form** — BSD awk on macOS rejects this with a syntax error. Stick to `grep | sed` pipelines for portability.
3. **`grep -c` exits 1 on zero matches** — under `set -eo pipefail`, this kills the script. Wrap with `{ grep ... || true; }` or `|| true` on the assignment.
4. **`grep -c X || echo 0` doubles the output** — when grep prints "0" AND exits 1, the `|| echo 0` runs on top, producing "0\n0". Use `|| true` + `${var:-0}` instead.
5. **iCloud preserves photo capture time as local mtime** — `find -newer $stamp` permanently strands photos whose capture time predates the most recent stamp touch. Switched the photo sync to manifest-based detection (sorted path-only list, then `comm -23`) to avoid this.
6. **WatchPaths in launchd is non-recursive** — for `Photos Library.photoslibrary/originals` (which uses hashed sub-dirs `0..F/`), file changes in subdirs don't bump the parent's mtime, so WatchPaths never fires. The hourly StartInterval safety net is the only thing actually triggering the photo sync.
7. **Photos.app holds a brief exclusive lock on `.photoslibrary`** at regular intervals — `find` returns 0 files during the window. The script now retries `find` up to 3 times with 30s sleeps between attempts before declaring sanity-gate failure.
8. **Sanity gate is non-negotiable** — if `wc -l CURRENT < (wc -l MANIFEST * 90 / 100)` and manifest has >1000 entries, abort the run without modifying state. Without this, an early-2026-05-02 incident wiped the entire photo manifest in 1 second when `find` returned 0 during a Photos.app lock window.
9. **Atomic manifest writes with rotation** — write to `manifest.new`, `mv` over current, keep previous as `manifest.last` for trivial rollback. Never write directly to manifest.
10. **DRY_RUN env var** — `DRY_RUN=1 bash ~/bin/immich-photo-sync.sh` runs detection + emits a `dryrun` Loki event but skips the upload AND manifest write. Use this for safe validation before any structural change.
11. **Grafana provisioning API gotcha** — `X-Disable-Provenance: true` on UPDATE strips the rule's `provenance=api` flag, which the API then rejects as a change ("cannot change provenance from 'api' to ''"). Only send the header on CREATE; omit on UPDATE.
12. **Grafana Reduce node `replaceNN` doesn't synthesize** — when a Loki query returns no series, `replaceNN` has no NaN value to replace; the input stays empty and downstream Math evaluates to empty. Workaround: extend the query window so it always has data (e.g. `[3h]` instead of `[1h]`).
13. **NC Photos timeline orders by `oc_files_metadata_index.meta_value_int`, NOT raw `oc_filecache.mtime`** — fixed 2026-05-10. rclone uploads landed with `mtime = upload-time` because osxphotos export wasn't passing `--touch-file`, so all photos appeared in upload order in NC's UI. Adding `--touch-file` to the osxphotos invocation fixes it forward; backfill for already-synced files needed disk `touch` + `occ files:scan` + direct SQL UPDATE on both `oc_files_metadata_index` (the indexed column NC sorts by) AND `oc_files_metadata.json` (NC's PHP keeps these consistent only on-write — direct JSON edits don't propagate to the index). See "NC Photos timeline ordering — capture date vs upload date" section below for the full recipe.
14. **exiftool `-FileModifyDate<DateTimeOriginal` ignores `OffsetTimeOriginal`** — even with `SubSecDateTimeOriginal` (which DOES include `+10:00` when read), exiftool drops the offset on write. Result: HEIC mtimes ended up shifted by tz-offset (10h late on Brisbane photos). Workaround: read with `exiftool -d %s` (UTC epoch) and write with bash `touch -d @epoch`. Caught this 2026-05-10 round 2 of the timeline-ordering fix.

## NC Photos timeline ordering — capture date vs upload date

NC32's Photos app sorts the timeline by `oc_files_metadata_index.meta_value_int` for `meta_key='photos-original_date_time'` — NOT by raw `oc_filecache.mtime`. NC's metadata extractor copies mtime into that index column on file change, but it does NOT reliably read EXIF `DateTimeOriginal` from HEIC files (it falls back to mtime even when imagick has the HEIF delegate). So the *real* sort key is whatever mtime the file landed with on disk.

When rclone uploads a file, the destination mtime defaults to upload time. Without intervention, every photo in NC appears stamped with the moment the sync ran, not when it was taken — and the timeline is sorted by upload order.

### Forward fix (in place since 2026-05-10)

The Phase 1.5 sync script (`scripts/nextcloud-photo-sync.sh`) passes osxphotos `--touch-file`, which sets each exported file's mtime to its EXIF capture date BEFORE rclone copies. NC's scan picks up the correct mtime → metadata index gets correct `meta_value_int` → timeline orders correctly. Verify the flag is present:

```bash
grep -n 'touch-file' applications/icloud-sync/scripts/nextcloud-photo-sync.sh
```

### JPG EXIF timezone trap (fixed 2026-05-24)

For HEICs, NC falls back to mtime (set correctly by `--touch-file`). For JPGs, NC *does* read EXIF `DateTimeOriginal` — but that tag stores local capture time with no timezone offset. NC treats it as UTC, shifting the photo forward by the timezone offset (e.g. +10h for Brisbane). NC even extracts `OffsetTimeOriginal` ("+10:00") but ignores it when computing `photos-original_date_time`.

The sync script now includes a post-export `exif-fix` stage (between osxphotos export and rclone copy) that overwrites `DateTimeOriginal` and `CreateDate` in JPGs with the mtime value (correct UTC), then restores the original mtime. Requires `exiftool` on the Mac Studio (`brew install exiftool`). The fix is idempotent — skips files where EXIF already matches mtime.

To fix an already-uploaded JPG, update both DB tables on the files VM:

```sql
-- Replace <fileid> and <correct_epoch> (= oc_filecache.mtime for the file)
UPDATE oc_files_metadata_index SET meta_value_int = <correct_epoch>
  WHERE file_id = <fileid> AND meta_key = 'photos-original_date_time';
UPDATE oc_files_metadata SET json = REPLACE(json, ':<wrong_epoch>', ':<correct_epoch>')
  WHERE file_id = <fileid>;
```

### Backfill recipe (when a batch landed without `--touch-file`)

Run on the [`files`](../../virtual-machines/files/README.md) VM. exiftool reads UTC-correct epochs (timezone-aware via `SubSecDateTimeOriginal`); bash `touch` writes mtime; `files:scan` refreshes oc_filecache.mtime; direct SQL syncs `oc_files_metadata_index` and `oc_files_metadata.json`.

```bash
# 1. Install exiftool on the host (NOT inside the container — touches files via NFS mount)
sudo apt-get install -y libimage-exiftool-perl

# 2. Touch script: see below — saves to /tmp/touch-from-exif-v2.sh, run as systemd-run unit
#    Reads via exiftool: SubSecDateTimeOriginal → CreateDate → MediaCreateDate → DateTimeOriginal
#    Filename-parses DOCUMENT_SCAN_*.jpg (no EXIF on those)
#    Skips UUID-named JPGs (no EXIF, no derivable date)
sudo systemd-run --unit=nc-touch-v2 --no-block --uid=root /tmp/touch-from-exif-v2.sh
sudo cat /var/log/nc-touch-v2.log  # expect "ok=N doc_scan=M skip=K" + "DONE-CHOWN"

# 3. Refresh NC's filecache.mtime
sudo docker exec -u www-data nextcloud_web_1 php /var/www/html/occ files:scan \
  --path='you@example.com/files/Photos/iCloud-Camera'

# 4. Sync metadata index + JSON from updated mtime (NC's auto-extraction may not pick up
#    files where EXIF read fails — explicit SQL ensures index is consistent)
sudo docker exec nextcloud_db_1 mariadb -u root -p<DB_ROOT> nextcloud -e "
UPDATE oc_files_metadata_index i
JOIN oc_filecache f ON f.fileid = i.file_id
SET i.meta_value_int = f.mtime
WHERE i.meta_key = 'photos-original_date_time'
  AND f.path LIKE 'files/Photos/iCloud-Camera/%'
  AND f.storage IN (SELECT numeric_id FROM oc_storages WHERE id LIKE 'home::alice%');

UPDATE oc_files_metadata m
JOIN oc_filecache f ON f.fileid = m.file_id
SET m.json = JSON_SET(m.json, '\$.\"photos-original_date_time\".value', f.mtime)
WHERE f.path LIKE 'files/Photos/iCloud-Camera/%'
  AND f.storage IN (SELECT numeric_id FROM oc_storages WHERE id LIKE 'home::alice%')
  AND JSON_EXTRACT(m.json, '\$.\"photos-original_date_time\".value') IS NOT NULL;
"

# 5. User hard-refreshes the Photos page (Cmd+Shift+R)
```

### touch-from-exif-v2.sh

```bash
#!/bin/bash
ROOT='/srv/nextcloud-data/nextcloud/data/you@example.com/files/Photos/iCloud-Camera'
LOG='/var/log/nc-touch-v2.log'
: > "$LOG"; ok=0; skip=0; doc=0
while IFS= read -r -d '' f; do
  base=$(basename "$f")
  # Filename-parse: DOCUMENT_SCAN_N_YYYYMMDD_HHMMSS.jpg (Brisbane local +10:00)
  if [[ "$base" =~ DOCUMENT_SCAN_[0-9]+_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\. ]]; then
    epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]} +10:00" +%s 2>/dev/null)
    [[ "$epoch" =~ ^[0-9]+$ ]] && { touch -d "@$epoch" "$f"; doc=$((doc+1)); continue; }
  fi
  # exiftool read as UTC epoch — first matching tag wins
  epoch=$(exiftool -d %s -api QuickTimeUTC=1 \
    -SubSecDateTimeOriginal -CreateDate -MediaCreateDate -DateTimeOriginal \
    -s -s -s "$f" 2>/dev/null | head -1 | tr -d ' ')
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    touch -d "@$epoch" "$f"; ok=$((ok+1))
  else
    skip=$((skip+1)); echo "SKIP: $f" >> "$LOG"
  fi
done < <(find "$ROOT" -type f \( -iname '*.heic' -o -iname '*.heif' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v' \) -print0)
echo "ok=$ok doc_scan=$doc skip=$skip" >> "$LOG"
chown -R www-data:www-data "$ROOT"
echo "DONE-CHOWN" >> "$LOG"
```

### Diagnostic: is a specific photo at the right date?

```sql
SELECT f.name, FROM_UNIXTIME(f.mtime) AS fc_mtime,
       FROM_UNIXTIME(i.meta_value_int) AS sort_key
FROM oc_filecache f
LEFT JOIN oc_files_metadata_index i
  ON i.file_id = f.fileid AND i.meta_key='photos-original_date_time'
WHERE f.name = 'IMG_XXXX.HEIC';
```

- `fc_mtime` wrong → file's on-disk mtime is wrong; touch it
- `fc_mtime` right but `sort_key` wrong → metadata index out of sync; SQL UPDATE
- Both right but UI still wrong → client-side cache; hard-refresh

## Reminders / Bookmarks / Notes — Mac-Studio CloudKit mirrors

Phase 6.1.5 (Reminders), 6.2 (Bookmarks), and 6.3 (Notes) all run on Mac Studio. They share a pattern: read the local Apple data store, push to a Nextcloud app, manifest-driven incremental sync, Loki HTTP push for observability.

| Phase | Source | Read mechanism | Nextcloud app | Trigger |
|---|---|---|---|---|
| 6.1.5 | Apple Reminders | EventKit via PyObjC | Tasks (CalDAV) | `EKEventStoreChangedNotification` daemon (10s debounce) |
| 6.2   | Safari Bookmarks | `plistlib` on `~/Library/Safari/Bookmarks.plist` | Bookmarks (REST v2) | launchd `WatchPaths` on `~/Library/Safari/` |
| 6.3   | Apple Notes | snapshot-copy of `NoteStore.sqlite` + sidecars, gzip+protobuf decode | Notes (REST v1) | launchd `WatchPaths` on `~/Library/Group Containers/group.com.apple.notes/Container_v1/Stores` |

**Files (canonical source under repo, deployed to Mac Studio at `~/bin/` and `~/Library/LaunchAgents/`):**

```
applications/icloud-sync/scripts/bin/
  icloud-reminders-cloudkit-sync.{py,sh}
  icloud-reminders-cloudkit-watcher.py        # event daemon
  icloud-bookmarks-sync.{py,sh}
  icloud-notes-sync.{py,sh}
applications/icloud-sync/scripts/LaunchAgents/
  com.mineracks.icloud-reminders-cloudkit-sync.plist
  com.mineracks.icloud-reminders-cloudkit-watcher.plist
  com.mineracks.icloud-bookmarks-sync.plist
  com.mineracks.icloud-notes-sync.plist
```

### Auth

All three reuse `~/.config/icloud-reminders-cloudkit/env` (Nextcloud app password + base URL). Each can be split out to its own env file if per-integration revocation matters; the orchestrators look at `~/.config/icloud-{bookmarks,notes}/env` first and fall back to the reminders one. Future option: split tokens.

### TCC

LaunchAgents invoke through `/usr/bin/env` so `env` is the TCC responsible-process. `env` has been granted:
- **Reminders Automation** (System Settings → Privacy & Security → Automation) — covers Reminders sync
- **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access) — covers reading Safari plist and the Notes Group Container

Both grants are one-time and persist across reboots. SSH-driven runs work without the env grants because `sshd-keygen-wrapper` already has FDA + Reminders Automation by default.

### Loki labels

Each phase emits to Loki at `http://LOKI_HOST:3100/loki/api/v1/push` via `_loki_push()` in `hb()`:

| Phase | Labels |
|---|---|
| Reminders sync | `{job="icloud_reminders_cloudkit", host="mac-studio", unit="icloud-reminders-cloudkit-sync"}` |
| Reminders watcher | `{job="icloud_reminders_cloudkit", host="mac-studio", unit="icloud-reminders-cloudkit-watcher"}` |
| Bookmarks | `{job="icloud_bookmarks", host="mac-studio", unit="icloud-bookmarks-sync"}` |
| Notes | `{job="icloud_notes", host="mac-studio", unit="icloud-notes-sync"}` |

### Sentinel rules (in `alerting.yml`)

| UID | Window | Trigger |
|---|---|---|
| `icloud-reminders-cloudkit-stale` | 30m | watcher's `event=alive` heartbeat (every 5m) — alert if zero in 30m |
| `icloud-bookmarks-sync-stale` | 12h | sync's `event=synced\|idle` |
| `icloud-notes-sync-stale` | 12h | sync's `event=synced\|idle` |

All use `noDataState: OK`, `for: 5m`, `keep_firing_for: 1h`, severity `warning`.

### Manifest format

Each sync writes `~/Library/Logs/icloud-{reminders-cloudkit,bookmarks,notes}-sync/manifest.json` keyed by the cloud-stable identifier (Reminders: `EKReminder.calendarItemExternalIdentifier`; Bookmarks: Safari `WebBookmarkUUID`; Notes: `ZICCLOUDSYNCINGOBJECT.ZIDENTIFIER`). Each entry stores `{nc_id, sha, …}` for incremental SHA-based diff. Bookmarks additionally caches a folder-id map. The Notes sync runs against a snapshot copy of `NoteStore.sqlite` + `-wal` + `-shm` in `tempfile.mkdtemp()` to bypass Notes.app's exclusive lock without bypassing the WAL (where most recent edits live).

### Operational gotchas (specific to these three)

- **`exec /usr/bin/python3` in the wrapper sh defeats the EXIT trap.** Bash gets replaced, the trap never fires, the lockfile leaks until the 5-min stale-clear. All three wrappers run python as a child instead. (Bit us in Phase 6.3, fixed retroactively across all three.)
- **`sqlite3` URI flag `immutable=1` blinds you to the WAL.** Notes.app keeps the working set in `-wal` until checkpoint. With `immutable=1` we saw 89 of 260 notes; without it we hit Notes.app's lock; the snapshot-copy approach works around both. (Phase 6.3.)
- **Most Apple Notes attachment originals are NOT on disk.** Apple stores them in CloudKit and only fetches on-demand. `~/Library/Group Containers/group.com.apple.notes/Accounts/<uuid>/Media/` typically has fewer files than the attachment count in the SQLite store; the rest are FallbackImages (thumbnails). V1 doesn't sync attachments at all (better than syncing thumbnails-only and pretending they're complete).
- **Apple Notes attribute_runs** (formatting: bold, headings, lists, checklists) are encoded in nested protobuf siblings of the body string. Mapping them faithfully to Markdown is non-trivial. V1 ships plain text (which is what 95%+ of notes contain anyway). Markdown is a Phase-2 enhancement.
- **AppleScript Notes / Reminders bridge is unworkable on CloudKit-backed data.** Both `tell application "Notes" to count of notes` and (originally) the Reminders JXA enumerator hang at `-1712` after 28+ seconds because each property access triggers a synchronous CloudKit fetch. Reminders went to EventKit (Cocoa-level, fast). Notes went straight to SQLite (no EventKit equivalent).

### Sanity gate (Notes only)

`icloud-notes-sync.py` refuses to sync if the source-store note count drops more than 10% vs the prior manifest. Prevents a corrupted local store from cascading deletions to Nextcloud. Returns exit code 2 + `event=sanity_gate_tripped` heartbeat on trip. First run skips the gate (manifest empty). Same pattern as the photo-sync gate from Phase 1.5.

### Roadmap items still open across these three

- Bookmarks: Floccus on iOS Safari → point at Nextcloud Bookmarks → mobile bookmarks feed back in (Day 2 enhancement).
- Notes: markdown rendering of attribute_runs (deeper protobuf decoding); attachment handling (parking until Apple makes originals locally available, or until we accept thumbnail-only).
- All three: tokens live in the shared Reminders env file. Splitting per-integration aligns with Apple's per-integration revocation principle.

## Carry-forward

- **Photos.app lock root-cause investigation** — `lsof` capture during a future failing :51 firing would tell us exactly what process holds the bundle. Lower priority now that the retry loop handles it.
- **Auto-sync repo → logs VM** — currently you manually `scp` updated files to `/opt/loki-stack/` after a repo edit. A git-pull cron on logs VM (or a webhook from Gitea) would close that loop.
- **Add an Immich-side heartbeat** — the photo sync currently trusts `immich-cli`'s exit code. A real validation would check Immich's own DB (asset count delta) post-upload.
- **Sentinel alert audit** — sweep all alerts for misapplied `noDataState=Alerting` on "fire-on-positive-event" rules. The Tang alert (`synth-tang-all-down`) had this bug — a fire-on-no-data alert that fired on the healthy state. Fixed 2026-05-02.
- **`icloud-drive-hourly-stale` and `icloud-documents-15m-stale`** still use `noDataState=Alerting` — they should be migrated to the `or vector(0)` + `noDataState=OK` pattern that `immich-sync-stale` uses, for cleaner bootstrap behavior.

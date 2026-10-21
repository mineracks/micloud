# iMessage + SMS Mirror (Phase 8.1)

Append-only archive of Apple **iMessage** + **SMS/MMS** history into Nextcloud,
as browsable per-conversation HTML with media. Part of the
[iCloud sovereign-backup epic](../../roadmap/icloud-sovereign-backup/README.md)
(Phase 8 — Messages). V1 is **Nextcloud-only**; the unified Datasette
`messages-mirror` VM and the other chat platforms (Telegram/WhatsApp/Signal)
are later sub-phases.

## Why it runs on the Mac Studio

The Mac Studio (`relay-mac`) is the only host signed into the iCloud
account, so it's the only place `~/Library/Messages/chat.db` is populated with
the full **Messages-in-iCloud** history. This is the same Mac-as-adapter pattern
as Phase 6.1.5 (CloudKit Reminders). Full Disk Access is already granted to the
process that runs these jobs — no TCC prompt needed.

## Data flow

```
~/Library/Messages/chat.db  (live, 87k msgs, 2014→now, iMessage + SMS)
        │  sqlite3 ".backup"  (online, read-only — live DB never written)
        ▼
~/imessage-mirror-staging/chat-copy.db
        │  imessage-exporter -f html -c full   (HEIC→JPEG, MOV→MP4 via ffmpeg/sips)
        ▼
~/imessage-mirror-staging/full-html/   (per-conversation *.html + attachments/)
        │  rclone copy --checksum   (content-hash delta; only changed convos + new media move)
        ▼
nextcloud:Messages/iMessage/   (files VM 180, user you@example.com)
```

- **One-way by construction.** The live DB is only ever read via SQLite's online
  `.backup`; nothing writes back to Apple. Satisfies `strict_oneway_sync_semantics`
  without a wrapper.
- **Append-only.** `rclone copy` (not `sync`) — a message/conversation deleted on
  the phone is **not** removed from the mirror.
- **Deterministic export.** `imessage-exporter` produces byte-identical HTML for
  unchanged conversations, so `--checksum` skips them; only conversations that
  gained messages + genuinely new attachments transfer each run.

## Components

| Piece | Where |
|---|---|
| Sync script (source of truth) | `scripts/bin/imessage-mirror-sync.sh` → deployed `~/bin/imessage-mirror-sync.sh` |
| LaunchAgent | `scripts/LaunchAgents/com.mineracks.imessage-mirror-sync.plist` → `~/Library/LaunchAgents/` |
| Exporter | `imessage-exporter` (Homebrew), `ffmpeg` + `imagemagick` + `sips` for media conversion |
| rclone remote | `nextcloud:` (WebDAV → `http://TAILNET_HOST:8080/.../you@example.com/`) |
| Schedule | daily @ 05:17 (`StartCalendarInterval`), offset from photo `:00/:30` and documents `:15` |
| Log | `~/Library/Logs/imessage-mirror-sync.log` (+ `…-launchd.log`) |
| Loki heartbeat | `{job="imessage_mirror",host="mac-studio",script="imessage-daily"}` — `started`/`idle`/`uploaded`/`failed`/`locked` |

## Backfill (one-time, done 2026-06-08)

The initial 12-year backfill (4,135 conversations, 8,892 attachments, **9.1 GB**)
was **not** pushed via per-file WebDAV — that crawled at ~0.6 files/sec (Nextcloud
per-file locking/chunk-assembly overhead) and would have taken 4+ hours. Instead:

1. `tar cf imessage-full.tar` of the export on the Studio.
2. `rclone copy` the single tarball to `nextcloud:Messages/_import/` (one streaming
   file, minutes).
3. On the `files` VM, extract **inside the container as `www-data`** (correct
   ownership, no chown):
   ```bash
   docker exec -u www-data nextcloud_web_1 sh -c \
     'cd /var/www/html/data/you@example.com/files/Messages && \
      tar xf _import/imessage-full.tar -C iMessage && rm -rf _import'
   docker exec -u www-data nextcloud_web_1 php occ files:scan \
     --path="you@example.com/files/Messages"
   ```

**Lesson:** bulk-import thousands of small files into Nextcloud via tar + server-side
extract + `occ files:scan`, never per-file WebDAV. Steady-state daily deltas are
small, so the forward sync uses ordinary `rclone copy --checksum`.

## Operating

```bash
# Manual run (synchronous; full export + checksum delta upload, ~5 min)
ssh relay-mac '~/bin/imessage-mirror-sync.sh'

# Watch live log
ssh relay-mac 'tail -f ~/Library/Logs/imessage-mirror-sync.log'

# launchd state / last exit
ssh relay-mac 'launchctl list | grep imessage'

# Fire now, ignoring schedule
ssh relay-mac 'launchctl kickstart -k gui/$(id -u)/com.mineracks.imessage-mirror-sync'
```

(Mac Studio is reached via the `studio-tasks` MCP, not direct SSH from the
fleet — see memory `mac_studio_host`. `~` is `/Users/USERNAME`.)

## Known limitations / Day-2 enhancements

- **Contact names.** V1 exports without `--contacts-path`, so personal
  conversations are identified by phone number (business/email senders still
  resolve). Adding `-n <AddressBook .abcddb>` resolves names *inside* the HTML
  (filenames stay as the identifier). Because it changes HTML content, enabling
  it requires a one-time re-export + re-push (use the fast tar path, not WebDAV)
  to keep checksums consistent. AddressBook DB:
  `~/Library/Application Support/AddressBook/Sources/<uuid>/AddressBook-v22.abcddb`.
- **iCloud-offloaded attachments.** Media that's been offloaded from the Studio
  ("Optimize Mac Storage") can't be exported until downloaded — the very oldest
  attachments may be incomplete. Same class as the Photos pipeline; see memory
  `macos_photos_silent_optimise_switch`.
- **Re-conversion cost.** Each daily run re-exports the full history (re-converts
  ~18 GB of media, ~2.5 min CPU) then uploads only deltas. Acceptable; a
  persistent-export-dir optimisation (skip already-converted attachments) is
  possible later if needed.
- **Observability follow-ups (not yet wired):** a Grafana dashboard row and a
  Sentinel `imessage-mirror-stale` alert (no heartbeat in >36 h) consuming the
  `{job="imessage_mirror"}` stream. The heartbeats are already emitted; only the
  dashboard/alert wiring remains. (Telegram alert delivery is separately under
  repair — see journal 2026-06-07.)
- **Viewing in Nextcloud.** The HTML opens via the Nextcloud desktop client or by
  download; the web UI may download rather than render HTML inline. Message text
  is full-text searchable regardless.

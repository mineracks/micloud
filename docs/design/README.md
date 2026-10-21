# Epic: iCloud Sovereign Live Backup

## What this is

A self-hosted, real-time shadow copy of every piece of data stored in
Apple iCloud — photos, documents, email, passwords, calendars, contacts,
bookmarks, and more — running on mineracks-owned infrastructure.

The goal is **sovereignty over your own data**. Apple iCloud is
convenient, but you're one account lockout, Terms of Service change, or
data centre incident away from losing decades of personal data overnight.
This epic creates a live backup that runs continuously alongside iCloud,
so that if Apple access is ever lost, nothing of value disappears.

## Why

- **Account risk** — Apple can disable an iCloud account for any reason
  (payment issues, false-positive fraud detection, policy disputes).
  When locked out, you lose access to *everything* simultaneously:
  photos, documents, passwords, email, calendar, contacts.

- **No export path** — Apple provides no automated bulk export of iCloud
  data. The manual "Request a copy of your data" process takes days and
  delivers incomplete archives. By then it may be too late.

- **Vendor lock-in** — the deeper you go into the Apple ecosystem, the
  harder it is to leave. A sovereign backup means the Apple ecosystem
  is a convenience, not a dependency.

- **Data longevity** — iCloud is a subscription. If you stop paying,
  data gets deleted after a grace period. Self-hosted storage on
  hardware you own has no subscription and no deletion timer.

- **Privacy** — Apple scans iCloud data (including photos) for various
  purposes. Self-hosted copies are not subject to third-party scanning.

## Architecture

```
Apple iCloud (2 TB plan)
      │
      ├── iCloud Photos (848 GB)
      │         │
      │         ▼ macOS Photos → Mac Studio → immich-cli (full library)
      │         Immich (photos VM 171) ✅ DONE
      │         ▼ + osxphotos --from-date 2026-05-08 → rclone WebDAV
      │         Nextcloud Photos/iCloud-Camera/ (files VM 180) ✅ DONE (Phase 1.5)
      │
      ├── iCloud Drive (488 GB)
      │         │
      │         ▼ macOS iCloud sync → Mac Studio → rclone
      │         Nextcloud (files VM 180) ✅ DONE
      │
      ├── Mail (82 GB)
      │         │
      │         ▼ mbsync from imap.mail.me.com → mail-mirror VM
      │         /srv/mail-mirror/Maildir/ + Dovecot read-only IMAP 🔄 IN PROGRESS
      │         (Phase 3 — bulk INBOX still pulling at ~9.7k msgs/h)
      │
      ├── Keychain / Passwords
      │         │
      │         ▼ Manual quarterly: Passwords.app CSV → bw import safaricsv
      │         VaultWarden (vault VM 810, dedicated tunnel, Litestream PITR
      │         to db-backup + R2) ✅ DONE 2026-05-09 (Phase 4 — shadow
      │         mirror; iCloud Keychain stays authoritative)
      │
      ├── Calendars
      │         │
      │         ▼ Python (raw CalDAV via requests) on integr8
      │         Nextcloud Calendar (files VM 180) ✅ DONE
      │
      ├── Contacts
      │         │
      │         ▼ Python (raw CardDAV via requests) on integr8
      │         Nextcloud Contacts (files VM 180) ✅ DONE
      │
      ├── Reminders (legacy CalDAV: 13 lists, 690 items)
      │         │
      │         ▼ Python CalDAV on integr8 (Phase 6.1)
      │         Nextcloud Tasks (files VM 180) ✅ DONE
      │
      ├── Reminders (CloudKit: 48 lists, 2,322 items including post-iOS-13)
      │         │
      │         ▼ Mac Studio → EventKit (PyObjC) → daemon w/ debounce → CalDAV
      │         Nextcloud Tasks (files VM 180) ✅ DONE 2026-05-08 (Phase 6.1.5)
      │
      ├── Bookmarks (Safari, 105 items, 13 folders)
      │         │
      │         ▼ Mac Studio → plistlib → launchd WatchPaths → Bookmarks REST v2
      │         Nextcloud Bookmarks (files VM 180) ✅ DONE 2026-05-08 (Phase 6.2)
      │
      ├── Notes (Apple Notes, 260 items, 4 user folders)
      │         │
      │         ▼ Mac Studio → SQLite snapshot + gzip+protobuf decode → Notes REST v1
      │         Nextcloud Notes (files VM 180) ✅ DONE 2026-05-08 (Phase 6.3)
      │
      ├── Health Data
      │         │
      │         ▼ Health Auto Export iOS app → HTTPS → ingester
      │         health-mirror VM (InfluxDB + Grafana + Datasette + SQLite, all-in-one)
      │         + daily JSON drop to iCloud Drive → Nextcloud (belt-and-braces)
      │         ✅ DONE — end-to-end live 2026-05-10 (8.14M historical + live streaming)
      │
      └── Family Usage (559 GB)
                │
                ▼ Separate iCloud accounts
                Out of scope (per-user decision)
```

## Architectural pattern: one function = one VM

Where this epic introduces a long-running sync/archive job that holds significant data on disk, the host follows the **single-function VM** pattern already established across the mineracks fleet (`cashu`, `lnvault`, `btcpay`, `calendar`, `meet`, etc.):

- One VM per function. Clone from the standard Ubuntu template, Tailscale-join, Promtail-equipped, PBS-backup-eligible, named for what it does.
- Distinct semantic naming:
  - **mirror** — continuously synced live copy, lagging by minutes/hours, reflects current source state. Examples: `mail-mirror` (Phase 3, mbsync from iCloud IMAP).
  - **archive** — point-in-time snapshots, often immutable, may not include current state. Examples: `health-archive` (Phase 7, quarterly Apple Health XML exports).

The convention matters because conflating "mirror" and "archive" semantics in one VM forces inaccurate naming. A `mail-mirror` is functionally different from a `health-archive` even though both store iCloud-sourced data.

**Single-function VMs preferred over a shared `archive`/`mirror` VM**, even when the marginal cost of one more VM is small:
- Each VM has its own identity in the inventory, Tailscale, PBS backup schedule, Sentinel alert namespace.
- Disk sizing per function — no over-provisioning to accommodate the union.
- Blast radius contained: a runaway sync job on one function VM doesn't starve another.
- "Miscellaneous" VMs drift in scope; single-function VMs stay focused.

The one tradeoff is operational ceremony: more VMs = more entries to track. Acceptable given the existing fleet pattern already runs ~45 VMs.

## ⚠️ Operational risk: iCloud quota silently breaks the photo chain

**Discovered 2026-05-08** (see `journal/79730723-2026-05-08.md` and memory `icloud_quota_full_silent_break.md`):

When the iCloud account is at quota, Apple silently pauses Mac sync. Both Phase 1 (Immich) and Phase 1.5 (Nextcloud Photos) depend on Mac Studio receiving fresh photos from iCloud — both run as `idle, 0 added` indefinitely without surfacing the cause. The pipeline alerts can't catch this because `idle` is technically a successful run.

**Mitigations in place / planned:**

- **Sentinel alert: iCloud free-space < 5%** (planned, see tasks). The right detector for this class of failure.
- **Phase 2.5: Documents migration to Nextcloud-only** (now urgent — see new section below). The 480 GB `~/Documents` folder is the largest single iCloud Drive consumer; moving it off iCloud frees nearly a quarter of the 2 TB quota and prevents future quota walls without paying Apple more.

**Apple One ceiling:** Apple One Premier ($49.95/mo) is Apple's highest bundle and includes 2 TB iCloud. There is no 4 TB or higher Apple One. Beyond 2 TB is iCloud+ standalone tiers stacked on top.

**Apple's resume-gating gotcha:** when iCloud is full and you try to re-enable iCloud Photos on a Mac, Apple's storage-upgrade dialog only allows tiers that fit the **full local library worst-case**, not the actual upload delta. With a ~918 GB local library, only the 6 TB tier ($44.99/mo) is selectable. Don't waste time trying lower tiers — they're disabled.

The whole point of this sovereignty epic is to avoid this kind of vendor lock; treat the quota as a forcing function, not a shopping list.

## Status

### ✅ Phase 1: Photos — COMPLETE (2026-04-28)

**What:** Full mirror of iCloud Photo Library to self-hosted Immich.

| | |
|---|---|
| **Source** | iCloud Photos (848 GB, 178k photos, 5k videos) |
| **Destination** | Immich on photos VM (171, pve-04) |
| **Sync method** | Mac Studio → immich-cli via launchd WatchPaths |
| **Access** | `immich.example.com` — Cloudflare Access + Google SSO |
| **Mobile** | Immich iOS app with Google SSO |
| **Latency** | Photo taken → appears in Immich: ~5 minutes (when iCloud sync chain is healthy) |
| **Status** | 177k photos uploaded, ML processing in progress. **Operational dependency:** silently degrades when iCloud quota is full — incident 2026-05-08 surfaced this for the first time. See "Operational risk" callout above. |

**Key learnings:**
- macOS Photos "Download Originals" must be enabled (vs Optimise Storage)
- `immich-cli` hangs on full-library re-crawl with 200k+ files — use
  incremental `find -newer` approach instead
- Cloudflare Access blocks mobile apps — need path-specific bypass for
  `/api/*` and `/.well-known/*`
- Mobile OAuth needs server-side redirect (`/api/oauth/mobile-redirect`)
  because Cloudflare rejects custom URI schemes

See: [`applications/immich/README.md`](../../applications/immich/README.md)

### ✅ Phase 1.5: Photos parallel mirror to Nextcloud (forward-only) — COMPLETE (2026-05-08)

**What:** A second, independent pipeline that mirrors **new** iCloud Photos (capture date ≥ 2026-05-08) into Nextcloud at `Photos/iCloud-Camera/{YYYY}/{YYYY-MM}/`, running in parallel to Phase 1's Immich pipeline. Built so the user has a single Nextcloud "pane of glass" for new photos alongside Drive/Mail/Calendars/Contacts/Tasks/Bookmarks. Existing 1.1 TB legacy photo library remains in Immich only — no double-storage of the back catalogue.

| | |
|---|---|
| **Source** | Same `.photoslibrary` bundle on Mac Studio that Phase 1 reads (`/Volumes/PhotosSSD/Photos Library.photoslibrary`). osxphotos 0.75.9 reads it without invoking Photos.app. |
| **Filter** | `osxphotos --from-date 2026-05-08` — capture-date filter at the export step. Older photos are structurally excluded; the legacy library can never accidentally land in Nextcloud. |
| **Destination** | Nextcloud user `you@example.com` (Google-SSO, NOT the legacy `umbrel` service user — matches the Phase 5/6 personal-data convention). Layout: `Photos/iCloud-Camera/{YYYY}/{YYYY-MM}/<original-filename>`. Photos tab indexes the user's home automatically. |
| **Sync engine** | `~/bin/nextcloud-photo-sync.sh` on Mac Studio. Pipeline: osxphotos export with `--update --skip-original-if-edited --directory '{created.year}/{created.year}-{created.mm}'` to a staging dir on `/Volumes/PhotosSSD/nextcloud-photo-sync-staging/`, then `rclone copy` (not `sync` — additive-only, never deletes on remote) via the new `nextcloud-photos` rclone remote. **Note:** `--download-missing` was tried originally and removed 2026-05-08 — when Photos.app isn't running on Mac Studio it hangs the AppleScript download call indefinitely. Mac Studio is "Download Originals" mode anyway, so the flag was redundant. |
| **Manifest separation** | osxphotos's own export-state DB at `<staging>/.osxphotos_export.db` is the manifest. Completely independent of the Immich manifest at `~/.immich-sync-manifest.txt`. A failure or rollback on either side cannot affect the other. |
| **Media coverage** | Default osxphotos export — stills + videos + Live Photo `.mov` motion components + bursts + RAW. Originals only (no edits via `--skip-original-if-edited`). |
| **Format** | HEIC pushed unmodified — Nextcloud's `imagick` extension has the HEIC + HEIF delegates loaded so Photos-tab thumbnails render natively. Videos land but show generic icons until ffmpeg is added to the Nextcloud container (Day-2 task). |
| **Cadence** | LaunchAgent `com.mineracks.nextcloud-photo-sync` with `StartCalendarInterval Minute=30` (fires :30 hourly) + `WatchPaths` on `originals/` as event trigger. Offset from Phase 1's :00 firing to avoid concurrent osxphotos against the same library. `RunAtLoad=false`. Throttle 60s. |
| **One-way guarantee** | Architecture-level. Mac Studio reads the local `.photoslibrary` (read-only AppleScript-free path via osxphotos → the .photoslibrary bundle). The `nextcloud-photos` rclone remote uses `rclone copy` (not `sync`) so deletions on iCloud cannot propagate destructively to Nextcloud. iCloud is touched only via Apple's normal Photos sync, outside our process. |
| **Auth** | Per-integration Nextcloud app token (vault: `vault_nextcloud_apptoken_photos_sync`). Mac Studio: `~/.config/nextcloud-photo-sync/env` (mode 600) and rclone `nextcloud-photos` remote with obscured pass. Independent revocation from the existing `vault_nextcloud_webdav_pass_obscured` used by drive-hourly + documents-15m. |
| **Observability** | Loki heartbeats `{job="nextcloud_photos_sync", host="mac-studio"}` per run. File-provisioned alert `nextcloud-photos-sync-stale` (6h window, `or vector(0)`, `noDataState: OK`, `keep_firing_for: 1h`). Dashboard row deferred to Day-2. |
| **Risk to Phase 1 (Immich)** | Effectively zero. Different manifest, different launchd unit, different output path, different rclone remote, staggered firing. Both scripts only read the library; Photos.app exclusive-lock contention is handled by osxphotos's `--retry 2` + the script's outer 3-attempt retry-with-backoff loop. |

**Steps:**
- [x] Verify osxphotos + rclone toolchain on Mac Studio (osxphotos 0.75.9 + rclone in /opt/homebrew/bin) — 2026-05-08
- [x] Verify Nextcloud HEIC preview support (imagick has HEIC + HEIF delegates) — 2026-05-08
- [x] Generate Nextcloud app token via `occ user:auth-tokens:add -n you@example.com`; store as `vault_nextcloud_apptoken_photos_sync` in `inventory/group_vars/all/vault.yml` — 2026-05-08
- [x] Add `nextcloud-photos` rclone remote on Mac Studio (`~/.config/rclone/rclone.conf`, password obscured) — 2026-05-08
- [x] Write `~/.config/nextcloud-photo-sync/env` on Mac Studio mode 600 — 2026-05-08
- [x] Build `~/bin/nextcloud-photo-sync.sh` (source of truth: `applications/icloud-sync/scripts/nextcloud-photo-sync.sh`) — 2026-05-08
- [x] DRY_RUN smoke test (osxphotos invocation + JSON report parse) — 2026-05-08, exit=0, 0 photos matched (no captures yet today)
- [x] rclone round-trip smoke test (write probe.txt → list → delete) — 2026-05-08, success
- [x] Install LaunchAgent `com.mineracks.nextcloud-photo-sync.plist` (StartCalendarInterval Minute=30 + WatchPaths originals/) — 2026-05-08
- [x] File-provision alert `nextcloud-photos-sync-stale` in `applications/icloud-sync/alerting.yml` and reload Grafana on logs VM — 2026-05-08
- [ ] **End-to-end test with a real new photo** — pipeline mechanics validated 2026-05-08 (DRY_RUN + rclone round-trip + clean idle live-fire run); awaiting first photo with capture date ≥ 2026-05-08 actually landing on Mac Studio. Currently blocked by the iCloud quota incident — once Mac Studio's iCloud sync resumes downloading new content, the next pipeline firing closes this out.
- [ ] **Day-2:** add `ffmpeg` to the Nextcloud container so video thumbnails render in Photos tab
- [ ] **Day-2:** add `📸 Photos — iCloud → Nextcloud (forward-only)` row to `applications/icloud-sync/grafana-dashboard.json` (clone of Phase 1's Photos→Immich row, queries rewritten for `{job=nextcloud_photos_sync}`)

**Why now / motivation:**

The user wants Nextcloud as the single pane of glass for the iCloud sovereign mirror — Drive (Phase 2), Mail (Phase 3), Calendars + Contacts (Phase 5), Reminders (Phase 6.1 + 6.1.5), Bookmarks (Phase 6.2), Notes (Phase 6.3 planned), and now Photos. The 1.1 TB legacy iCloud Photos library would cost ~700 GB of additional Nextcloud disk and a non-trivial re-import to mirror in full (see memory `option_a_immich_external_library_feasibility`); duplicating that cost for cosmetic UI consistency wasn't worth it. This forward-only path captures every new photo from 2026-05-08 onwards in both surfaces (Immich for ML/face-detection power, Nextcloud for the unified browsing experience), at the marginal cost of HEIC originals + videos in two places — typical ~50 MB/day, ~18 GB/year.

**Anti-patterns avoided:**

- **Don't share manifest with Immich script.** Coupled state means a bug or rollback in one pipeline can poison the other. We use osxphotos's own export DB at `<staging>/.osxphotos_export.db`, completely separate from `~/.immich-sync-manifest.txt`.
- **Don't use `rclone sync` (bidirectional or destructive).** `rclone copy` is additive-only — deletions on iCloud cannot propagate destructively to Nextcloud. Same Phase-5 lesson applied to the WebDAV layer.
- **Don't reuse the existing rclone WebDAV credential.** The Phase-5 per-integration revocation principle: a separate app token means the Photos pipeline can be revoked in isolation if compromised.
- **Don't run on the same minute as Phase 1.** Concurrent osxphotos against a Photos.app-locked library is the established 2026-05-02 failure mode — both scripts have retry loops, but staggering :00 / :30 makes overlap improbable in the first place.
- **Don't assume Nextcloud Photos previews "just work" for HEIC.** Verified `imagick::queryFormats()` returns both HEIC and HEIF before shipping. If those delegates were missing the user would see broken thumbnails everywhere and have to debug after-the-fact.

See: [`applications/icloud-sync/README.md`](../../applications/icloud-sync/README.md), [`applications/icloud-sync/scripts/nextcloud-photo-sync.sh`](../../applications/icloud-sync/scripts/nextcloud-photo-sync.sh)

### ✅ Phase 2: iCloud Drive — COMPLETE (2026-05-03)

**What:** One-way shadow copy of all iCloud Drive files to Nextcloud.

| | |
|---|---|
| **Source** | iCloud Drive (~488 GB) — `~/Desktop`, `~/Documents`, `~/Library/Mobile Documents/com~apple~CloudDocs/` |
| **Destination** | Nextcloud on files VM (180, pve-04) |
| **Sync method** | Mac Studio → rclone WebDAV via launchd, two scripts (`drive-hourly` + `documents-15m`) |
| **Data disk** | Expanded to 600 GB (2026-04-29) |
| **Access** | `nextcloud.example.com` — Cloudflare Access + Google SSO (with 12 path-bypass apps for sync clients/OIDC/sharing — see `nextcloud_cf_access_bypass_pattern` memory) |
| **Observability** | Loki heartbeats per run, file-provisioned Grafana dashboard + 3 stale-sync alerts (`{job="icloud_drive_sync", host="mac-studio"}`) |

**What got built:**
- `~/bin/icloud-drive-sync.sh` (drive-hourly) — `~/Desktop` + `~/Library/Mobile Documents/com~apple~CloudDocs/` (excluding Documents) → Nextcloud
- `~/bin/rclone-documents-sync.sh` (documents-15m) — `~/Documents` → Nextcloud
- launchd plists with `WatchPaths` + `StartInterval` safety net
- Grafana dashboard `https://grafana.example.com/d/immich-sync/icloud-synchronisation` (uid `immich-sync` — covers both photos + drive)
- 3 file-provisioned alert rules (`immich-sync-stale`, `icloud-drive-hourly-stale`, `icloud-documents-15m-stale`)

**Key landmines that cost time** (full list in the application README):
- BSD `mktemp` template syntax differs from GNU — `XXXXXX` must be trailing, not embedded. Stale literal `/tmp/...XXXXXX.log` from a buggy template blocked `documents-15m` for 36+ hours.
- `find -newer` strands old-mtime files because iCloud preserves capture time as mtime — switched photo sync to manifest-diff (sorted path lists + `comm -23`).
- WatchPaths is non-recursive — for `Photos Library.photoslibrary/originals` (hashed sub-dirs), the `StartInterval` is the only thing actually firing.
- A Photos.app exclusive lock window made `find` return 0 files and wiped the manifest in 1 second on 2026-05-02. Sanity gate now refuses to write a manifest with >10% size drop when prior manifest had >1000 entries.
- Dashboard Reduce node `replaceNN` doesn't synthesise — when Loki returns no series, the input stays empty. Workaround: extend window so it always has data.

See: [`applications/icloud-sync/README.md`](../../applications/icloud-sync/README.md)

### 📋 Phase 2.5: Documents → Nextcloud-only (decommission iCloud Drive sync) — PLANNED, NEW PRIORITY 2026-05-08

**What:** Stop syncing `~/Documents` (480 GB, the bulk of iCloud Drive's footprint) to iCloud, retain it locally on each Mac, and rely on Phase 2's existing `rclone-documents-sync.sh` Nextcloud mirror as the cross-device store. Frees ~480 GB from the iCloud quota — closing the gap that caused the 2026-05-08 silent break and enabling downgrade off any paid iCloud+ tier.

**Why now / motivation:**

The iCloud quota incident on 2026-05-08 (full breakdown in `journal/79730723-2026-05-08.md`) forced a $44.99/mo iCloud+ 6 TB add-on as a temporary unblock. The recurring spend continues until iCloud usage drops below 2 TB. The 480 GB `~/Documents` is the single biggest iCloud Drive consumer and is **already** mirrored to Nextcloud by Phase 2 — the engineering work is done. The remaining steps are operational: verify mirror integrity, flip the iCloud Drive toggle on each Mac, downgrade.

| | |
|---|---|
| **Source** | `~/Documents` on each Mac (Mac Studio, MacBook), 480 GB total |
| **Destination** | Already in Nextcloud via Phase 2 — `rclone-documents-sync.sh` runs every 15 min |
| **iCloud-side action** | System Settings → iCloud → iCloud Drive → "Desktop & Documents Folders" → **OFF** on each Mac |
| **Trade-off** | iPhone/iPad access to Documents shifts from native Files app → Nextcloud iOS app. Some workflows that depend on Files-app integration will need re-establishing through Nextcloud's mobile client. |
| **Storage impact** | ~480 GB drains from iCloud over a few days; Mac local storage unaffected (files stay on each Mac) |
| **Quota recovery target** | Below 1.5 TB iCloud usage → can downgrade iCloud+ from 6 TB → 0 (rely on Apple One Premier 2 TB) or 200 GB ($4.49/mo) for buffer |

**Steps:**
- [ ] **Verify mirror integrity:** compare `~/Documents` file count + total size on Mac Studio vs the Nextcloud-side `Documents/` folder. Spot-check the most recent ~50 modified files on Mac Studio and confirm they're present on Nextcloud with matching mtimes/sizes.
- [ ] **Spot-check iPhone workflows** that depend on Files-app access to Documents. Identify which ones break, plan replacements via Nextcloud iOS app.
- [ ] **Cancel redundant iCloud+ 50 GB standalone** ($1.49/mo). Independent of this phase but worth doing first; saves $18/yr regardless.
- [ ] **Flip "Desktop & Documents Folders" → OFF** on Mac Studio first (the photo-pipeline host). Wait 24-48 h for the iCloud-side drain to start showing in the storage breakdown. If broken anything, easy to flip back.
- [ ] **Flip on MacBook** once Mac Studio is settled.
- [ ] **Wait for iCloud usage to drop below 1.5 TB** (a few days as Apple lazy-purges).
- [ ] **Downgrade iCloud+ tier** from 6 TB → 0 or 200 GB. Saves $44.99/mo (or $40.50/mo if you keep the 200 GB buffer).
- [ ] **Update memory `phase15_photos_to_nextcloud.md`** with the closed-out quota dependency.

**Anti-patterns to avoid:**
- **Don't flip the toggle off without verifying Nextcloud mirror integrity first.** Phase 2's sync is reliable in steady state but spot-checking before a 480 GB iCloud purge is cheap insurance.
- **Don't flip both Macs simultaneously.** Stagger by a day so any unexpected behaviour on Mac Studio doesn't compound on MacBook.
- **Don't downgrade the iCloud+ tier early** — wait for iCloud usage to actually drop below 1.5 TB. Premature downgrade re-triggers the same gated-resume dialog that landed us on 6 TB in the first place (memory `icloud_quota_full_silent_break`).

**Why Phase 2.5 not "Phase 1.6" or similar:**
Phase 2 was about establishing the Drive→Nextcloud mirror. Phase 2.5 closes it out by decommissioning the iCloud-side dependency now that the mirror is the source of truth. Same numbering convention as Phase 1 (Immich) → Phase 1.5 (Nextcloud Photos parallel).

### 🔄 Phase 3: Mail — IN PROGRESS (design locked 2026-05-06, host = `mail-mirror` VM)

**What:** One-way **mirror** of all iCloud Mail (`you@example.com` Apple ID, ~82 GB across all folders) to a local Maildir on a dedicated `mail-mirror` VM. The mirror reflects current iCloud state with `*/15` lag — not a point-in-time archive. Optional second-stage: serve that Maildir via Dovecot so the Nextcloud Mail app gives you a browser UI on top of the mirror without touching iCloud directly.

**Naming**: `mail-mirror` (not `mail-archive`) per the single-function VM pattern in the epic preamble — "mirror" because the data tracks current iCloud state, not because it's frozen-in-time.

**Lessons applied from Phase 5 (calendars + contacts):**
1. The Nextcloud Mail app alone is NOT an archive — it's an IMAP client that reads from wherever you point it. Does not store anything locally. Useless on its own for sovereignty.
2. One-way sync MUST be enforced architecturally, not by convention. mbsync's `Sync Pull` mode never issues `APPEND`/`STORE`/`EXPUNGE` to the remote — that's the IMAP-protocol equivalent of Phase 5's `ReadOnlySession` HTTP wrapper.
3. Plain Maildir = one file per email = grep-friendly, fsck-friendly, no corruptible database.

**Locked-in design:**

| | |
|---|---|
| **Source** | iCloud IMAP `imap.mail.me.com:993` (TLS), Apple ID `you@example.com`, app-specific password |
| **Destination** | Local Maildir at `/var/lib/icloud-mail-archive/Maildir/` on the host TBD (see "Where it runs") |
| **Sync engine** | `mbsync` (isync) configured with `Sync Pull` — explicit one-way semantics at the IMAP protocol level |
| **One-way guarantee** | mbsync's pull-only mode is the security boundary. Configuration uses `Patterns *` for full coverage but omits `Slave/Far` write-back patterns, so even with bugs the wrapper cannot push back to iCloud |
| **Folder coverage** | All folders: `INBOX`, `Sent Messages`, `Drafts`, `Junk`, `Trash`, `Archive`, plus all custom folders. mbsync's `Patterns *` mirrors everything iCloud exposes. iCloud "Smart Inboxes" / VIPs are client-side only and don't exist in IMAP — they don't come across (intentional; they're per-device UI state, not archive content) |
| **Auth** | Vault as `vault_apple_id_app_password_imap` (separate label from the DAV password — Apple recommends one app password per integration so they can be revoked independently). Sourced via `/etc/icloud-mail/env` (mode 600 root) |
| **Cadence** | `*/15` cron (mail is less time-sensitive than calendars; iCloud's IMAP rate-limits faster polling anyway) |
| **State** | mbsync stores per-folder UID-validity + last-seen-UID state in `~/.mbsync/`. Pure files, easy to reset |
| **Observability** | Loki heartbeats `{job="syslog", host="<host>", unit="icloud-mail-sync"}` per run with per-folder counters: `inbox_added=N sent_added=N total_bytes=N elapsed=Ns errors=N` |
| **Alert** | `icloud-mail-sync-stale` file-provisioned via `applications/icloud-sync/alerting.yml` — fires if no successful run in 60min (looser window than calendars because */15 cadence) |
| **Dashboard** | New row `📨 Mail — iCloud → Maildir` in the icloud-sync dashboard, mirroring the established Health / Added (24h) / Changed / Deleted / Activity-over-time / Recent events pattern |

**Host: dedicated `mail-mirror` VM**

Provisioning spec:
- Clone from the Ubuntu 24.04 template (VMID 9000)
- 2 GB RAM, 2 vCPUs (mbsync is light)
- 32 GB root disk on `mineracks-storage-pve` (shared NFS)
- ~150 GB second data disk on `mineracks-storage-pve` mounted at `/srv/mail-mirror/Maildir/` (room for the 82 GB current load + headroom for growth)
- Tailscale-joined (auto via vault auth key, `--ssh=false` per the established pattern)
- Promtail installed pointing at `logs:3100` so heartbeats flow to Loki under `{host="mail-mirror"}`
- PBS backup schedule: daily, retain 14 days (the mail itself is sourced from iCloud, so we don't need long retention on the mirror)
- No Docker — mbsync runs as `mineracks` user via cron

**Optional Phase 3.5 — Browser UI on top of the archive:**

After the Maildir is populated, run a **Dovecot** instance on the same host pointed at `/var/lib/icloud-mail-archive/Maildir/` exposing IMAP on `localhost:143`. Then configure the Nextcloud Mail app to add a second account: server `localhost`, port 143, no TLS, user/password from a dedicated read-only IMAP user defined in Dovecot's userdb. End result: browse archived iCloud mail in the same Nextcloud UI as everything else, with Apple Mail's IMAP server completely uninvolved.

This is genuinely optional — the archive is fully usable via `grep`, `mu`, `notmuch`, or any IMAP client pointed at a local Dovecot. The Nextcloud-Mail-on-localhost approach is just nice for parity with Phase 5's "everything in one Nextcloud UI" experience.

**Steps:**
- [x] Confirm host choice (`mail-mirror` VM)
- [x] Provision `mail-mirror` VM (VM 780 on pve-04, TAILNET_HOST, 2 GB RAM / 2 cores / 20 GB OS + 150 GB data disk on shared NFS) — 2026-05-06
- [x] User: generate Apple app-specific password labelled `mineracks-mail-mirror` — 2026-05-06
- [x] Vault: add `vault_apple_id_app_password_imap` + `vault_apple_id_imap_username` (encrypted), update `vault.yml.example` placeholder — 2026-05-06
- [x] Install `isync` 1.4.4 (`mbsync`) — 2026-05-06
- [x] Write `/etc/icloud-mail/{mbsyncrc,imap.password}` (mode 640 root:mineracks); config defines pull-only sync with `Patterns *` and `Expunge None` — 2026-05-06
- [ ] Initial bulk sync — IN PROGRESS as of 2026-05-06 21:35 AEST (running under transient systemd unit `icloud-mail-initial-sync`; will take hours; check `du -sh /srv/mail-mirror/Maildir/` for progress)
- [ ] Verify Maildir tree populated; spot-check a few emails for content fidelity
- [x] Write `/usr/local/bin/icloud-mail-sync.sh` wrapper that emits Loki heartbeats — 2026-05-06
- [x] `*/15` root cron with `flock` — 2026-05-06 (will pick up where initial sync left off; flock ensures no overlap)
- [x] File-provisioned Sentinel alert `icloud-mail-sync-stale` in `applications/icloud-sync/alerting.yml` — 2026-05-06 (45-min window, `noDataState: OK`, `keep_firing_for: 1h`)
- [x] Dashboard row added (`📨 Mail`) with Health / Added (24h) / Changed / Deleted / Activity / Recent events panels — 2026-05-06
- [x] Runbook at `applications/icloud-mail-mirror/README.md` — 2026-05-06
- [ ] End-to-end test: send a mail to `you@example.com` from elsewhere, confirm it lands in `/srv/mail-mirror/Maildir/INBOX/new/` within 15-20 min (gated on initial bulk sync completing)
- [ ] (Optional) Dovecot setup + Nextcloud Mail integration as Phase 3.5

**Anti-patterns to avoid (lessons from Phase 5 disaster):**

1. **Do NOT use a tool with bidirectional sync as default mode.** `imapsync` is two-way capable; while it has a `--read-only-source` flag, the flag is per-invocation — easy to forget on a manual run, and a cron config bug would silently make it bidirectional. mbsync's `Sync Pull` mode is configuration-level and applies to all runs.
2. **Do NOT modify the Maildir between cron runs** — even seemingly-safe operations like rebuilding indices or deleting spam manually can cause mbsync to detect "remote-newer state" and trigger unexpected behaviour. The Maildir is read-only by convention; do searches/modifications on a copy.
3. **Do NOT use a daemon mode (`mbsync -W`)** — keeps an open IMAP connection that can fail in subtle ways. One-shot per cron run with explicit logging is more debuggable.
4. **Set conservative IMAP limits** — `MaxMessages 0` (don't cap) on initial sync, but consider `BytesPerSecond` / connection-rate limiting on Apple's side. iCloud will rate-limit aggressive clients with `OVERQUOTA` or temporary `BAD` responses.

**Subscribed/Smart-folder caveat:**
- iCloud "VIPs" and "Smart Inboxes" are client-side state in Mail.app — not IMAP folders. They don't archive. Acceptable: the underlying mail still gets archived via the actual folders the smart inboxes filter on.
- iCloud server-side rules (rules that file mail to specific folders) HAVE already run server-side by the time mbsync sees the IMAP — so the result of the rule (mail in the right folder) is what gets archived. The rule definitions themselves don't archive.

**What lives in vault (additions for Phase 3):**

| Key | Purpose |
|---|---|
| `vault_apple_id_imap_username` | iCloud Mail username for IMAP (`you@example.com`) — separate from `vault_apple_id_username` because Apple's IMAP rejects custom-domain Apple IDs and only accepts `@icloud.com`/`@me.com`/`@mac.com` aliases |
| `vault_apple_id_app_password_imap` | App-specific password for IMAP (separate from the DAV password so they can be revoked independently per Apple's per-integration recommendation) |

**Apple custom-domain Apple ID gotcha (2026-05-06):**
The Apple ID `you@example.com` authenticates fine to CalDAV/CardDAV (used in Phase 5) but FAILS at `imap.mail.me.com` with `AUTHENTICATIONFAILED` — Apple's IMAP server only accepts the iCloud Mail alias. Solution above: store the IMAP username separately. Future iCloud Mail integrations should NOT reuse `vault_apple_id_username`.

### ✅ Phase 4: Keychain → VaultWarden shadow mirror — COMPLETE (2026-05-09)

**Direction set with the user 2026-05-09:** iCloud Keychain remains *authoritative* (it's still where the user reads + writes day-to-day). VaultWarden is the **shadow mirror** so a GrapheneOS device — or any client without iCloud access — can read those credentials. Refresh cadence is quarterly; staleness up to ~60d acceptable since the source of truth is unchanged.

#### Sub-phase 4a — VaultWarden hardening (2026-05-09)

VaultWarden was already running on the Umbrel app on `playground` VM 140 (`vault.example.com` via shared `mineracks-pve-tunnel-01`). Migrated off ahead of importing the password vault — Umbrel-update container churn (already wiped lnd-direct-proxy and cln-direct-proxy twice in recent weeks) is unacceptable risk for the master credential store.

| | |
|---|---|
| New host | `mineracks-vm-vault` (VMID 810, pve-04, `TAILNET_HOST`) — single-function VM per `single_function_vm_pattern` |
| Image | `vaultwarden/server:1.36.0@sha256:d626d04934cd…` (upgraded from 1.34.3 mid-evening to fix bw CLI 2026.4 compat) |
| Tunnel | dedicated `vault-mineracks` (`f02a1b40-…`) — no longer sharing with chat/n8n/ghost |
| Migration data integrity | `rsa_key.pem` SHA256 verified byte-identical pre/post (`48c46d5d…0e0b6d2`) → existing Bitwarden client JWTs validate transparently, no re-login needed |
| Backup tier 1 (PITR) | Litestream → SFTP `db-backup:/var/lib/litestream/vault/` (RPO ~1s) → R2 via `r2-fast-mirror.sh` (per-minute) |
| Backup tier 2 (snapshot) | Nightly `sqlite3 .backup` + tarball, rsynced to `db-backup:/var/lib/sqlite-backups/vault/`, then R2 via `r2-sync.sh` |
| Restore drill | `litestream restore` produces a working sqlite — verified end-to-end |
| Dashboard surfaces | `service=vault tier=litestream` + `service=vault-snapshot tier=sqlite-snapshot` rows in the unified DB-backup dashboard |
| Sentinel | `icloud-reminders-cloudkit-stale`-style coverage via the dashboard's `vault stale` row alerts |

Runbook: `applications/vaultwarden/README.md` (full backup/upgrade/restore procedure) + `virtual-machines/mineracks-vm-vault/README.md` (VM-level facts).

#### Sub-phase 4b — Keychain CSV import (2026-05-09)

810 items now in VaultWarden (794 from Keychain + 16 pre-existing from the Umbrel migration). Procedure:

| | |
|---|---|
| Source | macOS **Passwords.app → ⋯ → Export All Passwords** (CSV, TouchID-gated) |
| Format | `safaricsv` in `bw import` — Apple Passwords export shape is identical to Safari's. (Older `applecsv` removed in bw CLI 2026.4+.) |
| Destination | VaultWarden, dedicated **`iCloud Keychain Mirror`** folder, wiped + refilled on each refresh — keeps the folder a current cache, leaves native Bitwarden-only items in OTHER folders untouched. |
| Driver | `scripts/keychain-to-bw.sh` on user's MacBook. Volatile staging via `hdiutil create -fs HFS+` (Tahoe broke `diskutil eraseDisk APFS` on ram-backed devices, so we use a sparse dmg + secure-delete on `EXIT` trap). CLI session locks on exit; CSV `rm -P`'d. |
| Cadence | Manual quarterly. iCloud Keychain has no API — every export path requires TouchID on a logged-in Mac, so fully-scripted-on-cron isn't possible. Acceptable since Keychain stays authoritative. |
| Drift alert | `icloud-keychain-import-drift` Sentinel rule, 60-day window — pings if the user forgets the quarterly refresh. |

#### What we explicitly didn't do

- **Not a migration.** User keeps iCloud Keychain as their daily driver — better autofill on iOS/Safari, native Apple ecosystem integration, etc. This phase is shadow-only.
- **Passkeys not covered.** Apple still doesn't allow passkey export. They live only in iCloud Keychain. If iCloud is ever lost, passkey-protected accounts need separate recovery (most have password fallback).
- **Reverse path not scripted.** If iCloud Keychain is ever lost: export from VaultWarden → re-import to a fresh iCloud account via Safari → File → Import. One-time, doesn't justify automation.

### ✅ Phase 5: Calendars + Contacts — COMPLETE (2026-05-06)

**What:** One-way mirror of iCloud calendars + contacts to Nextcloud, running every 5 min via root cron on `integr8`. ~11,076 items synced (8,111 events + 2,965 contacts).

**Final design** (after three failed iterations — see post-mortem below):

| | |
|---|---|
| **Source** | iCloud CalDAV (`https://caldav.icloud.com`) + CardDAV (`https://contacts.icloud.com`) |
| **Destination** | Nextcloud Calendar + Contacts on files VM (180), `you@example.com` user (Google-SSO account, NOT the legacy `umbrel` service user), names prefixed `iCloud — ` to distinguish from Nextcloud-native collections |
| **Sync engine** | Single Python script `/usr/local/bin/icloud-dav-sync.py` on `integr8` VM, `*/5` cron with `flock`. Uses raw `requests` (no vdirsyncer). |
| **One-way guarantee** | iCloud HTTP session is wrapped in a `ReadOnlySession` class that **refuses** PUT/POST/DELETE/PROPPATCH/MOVE/COPY/MKCALENDAR — even buggy code can't write back to iCloud. This is the architectural security boundary. |
| **Sanitisation** | Two patterns stripped in memory between iCloud GET and Nextcloud PUT (never on disk): `;ENCODING=*` params (Outlook-era leftover) and empty `URL;VALUE=URI:` lines (iPhone OS export quirk). Both make Sabre 415 if left in. |
| **Auth** | Apple app-specific password + Nextcloud app token, vault-stored, sourced via `/etc/icloud-dav/env` (mode 600 root) — never inline in cron |
| **Multi-calendar** | 3 iCloud calendars (filtered to those with >0 events in last 90d) map 1:1 to 3 Nextcloud calendars: `iCloud — Calendar`, `iCloud — Work Calendar`, `iCloud — Family`. Each toggleable in Nextcloud Calendar UI. |
| **State / incremental** | `/var/lib/icloud-dav-sync/state.json` maps `{icloud_href: [etag, nc_filename]}` per collection. Cron run typically <30s — only changed items fetched + uploaded. |
| **Observability** | Loki heartbeats `{job="syslog", host="integr8", unit="icloud-dav-sync"}` per run. Stale-sync alert `icloud-dav-sync-stale` file-provisioned via `applications/icloud-sync/alerting.yml`. |

**Subscribed-calendars caveat (still TODO):**
iCloud's "Subscribed" calendars (Holidays AU, third-party ICS feeds) are not CalDAV — they're Apple-side URL subscriptions and won't come across. Fix: add them as native subscriptions in Nextcloud Calendar → "+ New subscription" with their public ICS URLs. One-time setup, Nextcloud auto-refreshes thereafter. Not yet done — pending an audit of which subscribed calendars matter.

**Steps:**
- [x] Lock in design
- [x] Generate Apple app-specific password (`mineracks-dav-integr8`)
- [x] Install vdirsyncer + python3-caldav on integr8 (vdirsyncer ultimately not used — see post-mortem)
- [x] Discover iCloud collections + filter to active ones (3 of 16 calendars, 1 address book)
- [x] Initial sync of 11,076 items to Nextcloud
- [x] Set proper Nextcloud display names + restore from trash
- [x] Build the one-way Python script (`applications/icloud-dav-sync/icloud-dav-sync.py`) with `ReadOnlySession`
- [x] `*/5` cron with `flock`
- [x] Stale-sync alert file-provisioned (`applications/icloud-sync/alerting.yml` UID `icloud-dav-sync-stale`)
- [x] Runbook at [`applications/icloud-dav-sync/README.md`](../../applications/icloud-dav-sync/README.md)
- [x] End-to-end test: user adds event in iCloud → appears in Nextcloud within 5 min ✓
- [ ] **TODO**: Audit Apple-side subscribed calendars + manually subscribe Nextcloud Calendar to the same ICS URLs
- [ ] **TODO**: Dashboard rows in `applications/icloud-sync/grafana-dashboard.json` (Calendars / Contacts health stats — alert exists, dashboard panels deferred)

**Post-mortem — three failed designs before the working one:**

1. **vdirsyncer single-pair iCloud → Nextcloud direct.** Failed at HTTP 415 on every event due to `ENCODING=QUOTED-PRINTABLE` and empty `URL;VALUE=URI:` in iCloud-side iCalendar. Sabre is strict; iCloud is lenient.

2. **vdirsyncer two-pair: iCloud → filesystem → sed-sanitize → Nextcloud.** The sanitize step modified files between sync runs. vdirsyncer's bidirectional sync interpreted "staging changed" as "push staging back to iCloud", and **pushed ~3,000 sed-cleaned events back to iCloud** over multiple cron cycles before it was caught. iCloud events still functional (verified Marilyn dinner location + Apple Maps tap survived) but content was modified without consent. vdirsyncer 0.19 has no real one-way mode; `conflict_resolution = "a wins"` only handles two-sided conflicts, not one-sided staging changes.

3. **vdirsyncer two-pair + Python `icalendar` reserialize step.** Same failure mode as (2), amplified — the reserializer rewrote ~300 files canonically, and vdirsyncer pushed all 300 to iCloud. Killed mid-run.

4. **(Working) Single Python script with `ReadOnlySession`.** The only architecture where iCloud is provably never written to, regardless of bugs in downstream code. The HTTP session wrapper IS the security boundary.

If anyone is ever tempted to use vdirsyncer for a one-way pipeline in the future, re-read the `applications/icloud-dav-sync/README.md` post-mortem first.

### ✅ Phase 6: Bookmarks, Reminders, Notes — COMPLETE 2026-05-08

**What:** Shadow copies of the three remaining "small structured-data" iCloud services into Nextcloud-native apps. Direction set with the user 2026-05-07: **everything lands in Nextcloud apps** rather than splintering Notes off to Joplin — the simpler the consolidation, the easier the recovery story (one UI, one vendor relationship, one sync model).

**Status (2026-05-08): all three sub-phases shipped end-to-end** in one extended session. Steady-state metrics:

| Sub-phase | Items | First-run | Latency tap → Nextcloud | Trigger |
|---|---|---|---|---|
| 6.1.5 Reminders (CloudKit) | 2,322 reminders / 48 lists | 20m17s | 30–60s | EventKit `EKEventStoreChangedNotification` daemon, 10s debounce |
| 6.2 Bookmarks (Safari) | 105 bookmarks / 13 folders | 53s | ~30s | launchd `WatchPaths` on `~/Library/Safari/` |
| 6.3 Notes (Apple Notes) | 260 notes / 4 folders | 2m03s | ~30s | launchd `WatchPaths` on `~/Library/Group Containers/group.com.apple.notes/Container_v1/Stores` |

All three: per-phase Sentinel rule + Grafana dashboard row, manifest-driven incremental SHA diff, Loki HTTP push for observability, env-launcher TCC pattern (`/usr/bin/env` is the responsible-process — granted Reminders Automation + Full Disk Access manually once, all three syncs inherit). Survives Mac Studio reboots. Operational runbook captured in `applications/icloud-sync/README.md`.

Two architectural lessons captured along the way (now in journal + memory + this README's Phase 6.3 section):
- **AppleScript bridge is dead for any modern (post-iOS-13) Apple data.** Per-property access serialises CloudKit fetches and hangs at `-1712`. Reminders pivoted to EventKit/PyObjC; Notes pivoted to direct SQLite parse with gzip+protobuf body decode.
- **CoreData stores belong to Notes.app while it's running.** Snapshot-copy `NoteStore.sqlite` + `-wal` + `-shm` to a tempdir before opening; don't try `immutable=1` (it bypasses the WAL where most recent edits live).

The original sub-phases in difficulty order — kept below for the design rationale and unmet carry-forward items:

#### 🔄 Phase 6.1 — Reminders → Nextcloud Tasks (Easy)

iCloud Reminders are CalDAV `VTODO` items hosted on the same `caldav.icloud.com` endpoint that Phase 5 already syncs from. Effectively a **free extension** of the Phase 5 pipeline: same auth, same script, same `ReadOnlySession` security boundary, same observability.

| | |
|---|---|
| **Source** | iCloud CalDAV — same endpoint as Phase 5; reuses `vault_apple_id_app_password_dav`. iCloud Reminders Lists appear as CalDAV calendar collections containing `VTODO` components instead of `VEVENT`. |
| **Destination** | Nextcloud **Tasks** app on files VM (180), under the existing `you@example.com` user. Each iCloud Reminders List maps 1:1 to a Nextcloud task list, named `iCloud — <listname>` (matches the Phase 5 prefix pattern). |
| **Sync engine** | Reuse `/usr/local/bin/icloud-dav-sync.py` on `integr8`. Extend the discovery step to enumerate VTODO-bearing collections; reuse the same `ReadOnlySession` wrapper, same state file (`/var/lib/icloud-dav-sync/state.json`) keyed by collection. |
| **One-way guarantee** | Already provided by Phase 5's `ReadOnlySession` — refuses PUT/POST/DELETE/PROPPATCH/MOVE/COPY/MKCALENDAR to iCloud regardless of caller bugs. No new security boundary needed. |
| **Cadence** | `*/5` cron — same entry as Phase 5; new collections fall into the same cycle. |
| **Vault additions** | None — fully reuses Phase 5 credentials. |
| **Nextcloud app to install** | **Tasks** (`tasks`, official, GPL). UI sibling of Calendar; reads VTODOs from the same CalDAV collections Calendar already indexes. |

**Steps:**
- [ ] Install Tasks app: `occ app:install tasks`
- [ ] Enable Tasks for the `you@example.com` Nextcloud user
- [ ] Extend `icloud-dav-sync.py` discovery to include VTODO collections (one-line filter widening)
- [ ] Test against a single Reminders list end-to-end (add reminder in iCloud → appears in Nextcloud within 5 min)
- [ ] Roll out across all Reminders lists, naming each `iCloud — <listname>`
- [ ] Update dashboard row "Calendars + Contacts" to "Calendars + Contacts + Tasks" (single Loki heartbeat covers all)

#### 🔄 Phase 6.1.5 — CloudKit Reminders → Nextcloud Tasks (via Mac Studio AppleScript) — IN PROGRESS 2026-05-07

Discovered while shipping Phase 6.1: Apple's iOS 13 / macOS 10.15 (~2018) Reminders rebuild moved most lists from CalDAV-backed storage to a **CloudKit-only** backend that the `caldav.icloud.com` endpoint **deliberately does not expose**. App-specific passwords + `caldav.icloud.com` only surface "legacy" Reminders Lists; everything created/upgraded post-2018 (including most shared lists) is invisible. Phase 6.1 captured the legacy CalDAV side (13 lists, 690 reminders); this sub-phase fills the CloudKit gap.

**Why it matters for the commercial model:** the user's end goal is offering this as a sovereign-backup service to HNW Apple-ecosystem users. Legacy-CalDAV-only is not a sellable product. Capturing the post-2018 surface is required for a real "full continuous mirror".

**Architecture:** macOS Reminders.app on Mac Studio sees the merged CloudKit + legacy view (because the Mac is signed into the same iCloud account as the iPhone). AppleScript / JXA gives us programmatic read access to that merged view. We write VTODOs into Nextcloud Tasks via CalDAV the same way Phase 6.1 does, but into a separate `tasks-cloudkit-<list-hash>/` namespace so provenance stays clear.

| | |
|---|---|
| **Source** | macOS `Reminders.app` on Mac Studio (`tell application "Reminders"` / JXA `Application("Reminders")`). Iterates every list + every reminder including completed via `r.completed()`. |
| **Destination** | New Nextcloud calendars at `tasks-cloudkit-<sha1(list-id)[:16]>/`, separate from the `tasks-<uuid>/` namespace from Phase 6.1. |
| **Sync engine** | Three files on Mac Studio: `~/bin/icloud-reminders-cloudkit-export.js` (JXA enumerator → JSON to stdout), `~/bin/icloud-reminders-cloudkit-sync.py` (orchestrator: calls JXA, diffs against manifest, MKCALENDARs, builds VTODOs, PUTs via WebDAV), `~/bin/icloud-reminders-cloudkit-sync.sh` (flock + launchd entry point). |
| **One-way guarantee** | JXA helper uses `.lists()` / `.reminders()` / property getters only — never `make new reminder`, never `set` on existing items. CloudKit is touched only via Apple's normal sync, outside our process. |
| **Cadence** | `StartInterval: 3600` (hourly via launchd LaunchAgent). |
| **State** | `~/Library/Logs/icloud-reminders-cloudkit-sync/manifest.json` keyed `{list-id: {reminder-id: {mod, sha, fn}}}`. SHA of the full reminder dict is the change detector — modification_date alone misses some Apple-side renames. |
| **Auth** | Nextcloud app token (vault: `vault_nextcloud_apptoken_reminders_cloudkit_sync`), stored on Mac Studio at `~/.config/icloud-reminders-cloudkit/env` (mode 600). Per-integration revocation. |
| **Run host** | Mac Studio. Future commercial product = per-customer Mac mini in a rack. The same scripts work unchanged — only the env file (one customer's NC creds) and the iCloud-account login differ. |
| **Observability** | Loki `{job="syslog", host="mac-studio", unit="icloud-reminders-cloudkit-sync"}` heartbeats. New row on icloud-sync dashboard ('🔔 Reminders (CloudKit)'). New stale alert (3h window, `noDataState: OK`). |
| **TCC pre-flight (one-time)** | macOS Privacy & Security: grant `Automation` for `Reminders.app` to `osascript` AND grant the launchd entry point's owner `Full Disk Access`. First interactive run pops the dialogs. Without this, AppleEvent calls return `-1712 timeout`. |

**Steps:**
- [x] Discovery: confirm CalDAV/CloudKit split via direct test against caldav.icloud.com (13 collections returned vs many more on iPhone) — 2026-05-07
- [x] ~~Write `icloud-reminders-cloudkit-export.js` (JXA enumerator)~~ — 2026-05-07; **superseded** by EventKit/PyObjC enumeration on 2026-05-08 (JXA bridge unworkable on CloudKit-backed reminders, see `journal/79730723-2026-05-08.md` and memory `reminders_eventkit_vs_jxa.md`)
- [x] Write `icloud-reminders-cloudkit-sync.py` — EventKit-based enumerator + VTODO generation, MKCALENDAR-if-missing, deletion detection, manifest-driven diffing (rewritten 2026-05-08 to drop JXA)
- [x] Write `icloud-reminders-cloudkit-sync.sh` (flock wrapper) — 2026-05-07
- [x] Write LaunchAgent plist — 2026-05-07
- [x] Install scripts on Mac Studio, generate Nextcloud app token, write `~/.config/icloud-reminders-cloudkit/env` (mode 600) — 2026-05-08
- [x] Grant TCC permissions — `sshd-keygen-wrapper` covers SSH-driven runs; LaunchAgent inherits the same Aqua-session grants — 2026-05-08
- [x] `launchctl load ~/Library/LaunchAgents/com.mineracks.icloud-reminders-cloudkit-sync.plist` — 2026-05-08
- [x] First full run: `event=synced elapsed=1217s lists=48 reminders=2319 pushed=2319 changed=0 deleted=0 errors=0` — 2026-05-08
- [x] Incremental no-op run: 19s wall-clock total (442ms EventKit enumeration + 2,319 SHA-matched skips + manifest write) — 2026-05-08
- [ ] Verify: list count + reminder count in Nextcloud Tasks UI matches iPhone Reminders (= 48 lists, 2,319 reminders) — user eyeball check
- [x] Sentinel alert added (`icloud-reminders-cloudkit-stale` — 30m window, `noDataState: OK`, qualifying event `event=alive` from the watcher daemon — `applications/icloud-sync/alerting.yml`). Pending gitea push to land in Grafana via the auto-provisioning cron.
- [ ] Dashboard row "🔔 Reminders (CloudKit)" on the icloud-sync Grafana dashboard

**Why this generalises to the rack-of-Mac-minis SaaS architecture:**

The Mac is the only viable "iCloud client adapter" for CloudKit-private data. Everything past it (Nextcloud, Loki, alerting) is vendor-neutral and per-customer-isolated. The same pattern (Cocoa framework via PyObjC → Python → VTODO via WebDAV) works for: Notes (Phase 6.3), the legacy + CloudKit Reminders together (this phase), Bookmarks (Phase 6.2 reads `~/Library/Safari/Bookmarks.plist` — same Mac-as-adapter idea), Photos (Phase 1 already does it via immich-cli), Drive (Phase 2 via rclone). Per-customer Loki labels (`{customer="<id>"}`) plus per-customer Nextcloud instances scale by Promtail config rather than code.

**Anti-patterns (lessons from this phase):**
- **Don't drive Reminders extraction through AppleScript/JXA.** The bridge synchronously serialises one round-trip per property and stalls on CloudKit-backed items — a 90-reminder list timed out at 300s; a 2,319-reminder fleet was never going to complete. Use EventKit via PyObjC; same data, ~35,000× faster, no hangs. Memory: `reminders_eventkit_vs_jxa.md`.
- **Don't run the script under a `LaunchDaemon` (root, system context).** TCC permissions for Reminders are user-scoped and require an Aqua session. `LaunchAgent` (per-user, loaded into the user's GUI session) is the only path that gets Automation rights for Reminders.
- **Don't try to write back to Reminders.app.** The EventKit enumerator must remain read-only — `predicateForRemindersInCalendars_` + `remindersMatchingPredicate_` only. Never call `EKReminder.save:` or modify any property. iCloud is touched only via Apple's normal Reminders sync, outside our process.
- **Don't filter to `isCompleted == false`.** Completed reminders are the bulk of the sovereignty value (history). Pull everything.
- **Don't trust silence as success.** During the first 20-min full run, the script emitted only `event=started` and looked stuck. It was actually progressing fine — `hb()` only printed at the end. Always emit per-list/per-batch heartbeats with `flush=True` so progress is visible in real time.
- **Don't probe Cloudflare-fronted Nextcloud with default `Python-urllib/3.x` UA.** Cloudflare's bot detection returns `error code: 1010` and you'll waste time chasing a phantom auth issue. The script's own UA (`icloud-reminders-cloudkit-sync/1.0`) passes fine.

#### 📋 Phase 6.2 — Bookmarks → Nextcloud Bookmarks (Medium)

iCloud Bookmarks have **no standard sync protocol** — they live in CloudKit, surfaced only through Safari + Apple's private API. The path of least Apple-internals dependency is to read Safari's local cache, which Apple keeps in lock-step with iCloud whenever Safari is signed in:

| | |
|---|---|
| **Source** | `~/Library/Safari/Bookmarks.plist` on Mac Studio — binary plist, autorefreshed by Safari from CloudKit. We never touch CloudKit ourselves. |
| **Destination** | Nextcloud **Bookmarks** app on files VM (180). REST API at `/index.php/apps/bookmarks/public/rest/v2/bookmark`. |
| **Sync engine** | New script `~/bin/icloud-bookmarks-sync.sh` on Mac Studio + Python helper. Uses `plistlib` (stdlib) to walk the bookmark tree → diff against last-sync manifest → POST/PATCH/DELETE to the Nextcloud Bookmarks REST API. |
| **One-way guarantee** | Architecture-level: the Mac Studio script never opens `Bookmarks.plist` for write, never contacts CloudKit. Writes only flow inward (Mac → Nextcloud). Apple is read-only, and the read happens against a temp snapshot taken with `plutil -convert xml1`. |
| **Cadence** | Hourly (`StartInterval: 3600` in launchd). Bookmarks change rarely — even on travel days you might add 2-3. No need for `*/5`. |
| **Folder mapping** | Safari's bookmark hierarchy maps directly to Nextcloud Bookmarks folder tree. Each bookmark uses URL as the natural unique key (Nextcloud Bookmarks dedupes by URL automatically). |
| **State** | `~/Library/Logs/icloud-bookmarks-sync/manifest.json` — sorted list of `{url, title, folder_path}` from last successful sync. Drives the diff. Same shape as the existing `icloud-drive-sync` manifest pattern. |
| **Auth** | Nextcloud app token (vault: `vault_nextcloud_apptoken_bookmarks_sync`), HTTP Basic to `nextcloud.example.com`. New token per Apple's per-integration revocation principle. |
| **Run host** | Mac Studio — same launchd platform as the photo/drive syncs. |
| **Observability** | Loki `{job="syslog", host="mac-studio", unit="icloud-bookmarks-sync"}` heartbeats with `event=synced added=N changed=N deleted=N total=N elapsed=Ns`. New row on the icloud-sync dashboard. New stale alert (12h window — matches infrequency of changes). |
| **Nextcloud app to install** | **Bookmarks** (`bookmarks`, official, AGPL). Stable, has REST API, browser-extension compatibility (Floccus). Storage in MariaDB. Mobile clients work via Floccus. |

**Steps:**
- [x] Bookmarks app installed and REST v2 API reachable — 2026-05-08
- [x] ~~Generate Nextcloud app token; store as `vault_nextcloud_apptoken_bookmarks_sync`~~ — V1 reuses the Reminders env file (`~/.config/icloud-reminders-cloudkit/env`); split is a future task if per-integration revocation matters
- [x] Wrote `~/bin/icloud-bookmarks-sync.{py,sh}` on Mac Studio (Python uses stdlib `plistlib` + `urllib`, no third-party deps)
- [x] Initial bulk sync: 105 bookmarks across 13 folders pushed in 53s; 1 `about:blank` Safari placeholder filtered out post-deploy
- [x] launchd plist `com.mineracks.icloud-bookmarks-sync.plist` with WatchPaths on `~/Library/Safari/` (event-driven) + 6h `StartInterval` (safety net)
- [x] File-provisioned Sentinel alert `icloud-bookmarks-sync-stale` (12h window, `noDataState: OK`) — `applications/icloud-sync/alerting.yml`
- [x] Dashboard row added on icloud-sync dashboard
- [ ] **Carry-forward**: grant Full Disk Access to `/usr/bin/env` in System Settings → Privacy & Security → Full Disk Access. macOS protects `~/Library/Safari/Bookmarks.plist` under FDA — without it the launchd-context read fails with `PermissionError: Operation not permitted`. SSH-context runs work because `sshd-keygen-wrapper` already has FDA via Apple's Default. Once granted, the LaunchAgent (currently unloaded to avoid retry-loop) can be reloaded.
- [ ] Runbook addition under `applications/icloud-sync/README.md`
- [ ] (Day 2) Install Floccus on iOS Safari → point at Nextcloud Bookmarks → mobile bookmarks now also feed in

**Anti-patterns:**
- **Don't read `Bookmarks.plist` while Safari is writing it.** Small race window, but possible. Always snapshot with `plutil -convert xml1 -o /tmp/safari-bookmarks-snapshot.xml ~/Library/Safari/Bookmarks.plist` first; parse from the snapshot.
- **Don't dedupe by `(folder, title)`.** The same bookmark can intentionally appear in multiple folders. Dedupe by URL only; folder list is multi-valued.
- **Don't use Floccus on the Mac side as the sync engine.** Floccus is bidirectional — exactly what Phase 5's post-mortem warned against. We pull-only, programmatically. Floccus is fine for the iOS Safari → Nextcloud Bookmarks direction (Day 2 enhancement) because that path is conceptually outbound from the Mac's perspective.

#### 📋 Phase 6.3 — Notes → Nextcloud Notes (Hard)

Apple Notes have **no export API**. Three viable paths exist:

| Approach | Pros | Cons |
|---|---|---|
| **A. AppleScript export** (`tell application "Notes"`) | Native API; handles attachments via `body` HTML; survives Apple schema changes | Slow at 1000+ notes (~1s per note); first run prompts for Notes access |
| **B. Direct SQLite parse** of `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` | Fast; programmatic; existing tools (`apple-notes-liberator`, `apple_cloud_notes_parser`) | Brittle to Apple schema changes; needs Full Disk Access; binary plist embedded text decoding is non-trivial |
| **C. Hybrid** | Best of both | More code paths to maintain |

**Update 2026-05-08:** A (AppleScript) is dead — `tell application "Notes" to count of notes` times out at `-1712` after 2 minutes, exact same CloudKit-fetch hang as Reminders pre-EventKit. EventKit doesn't cover Notes. **B (direct SQLite parse) is what shipped**, with the snapshot-copy approach to avoid Notes.app's exclusive lock. Schema risk is acknowledged and mitigated by tolerant protobuf scanning (greedy text fallback if the standard field path moves under us). See journal entry for 2026-05-08.

| | |
|---|---|
| **Source** | macOS Notes.app on Mac Studio (`tell application "Notes"`). Iterate every note, capture `id`, `name`, `modification date`, `body` (HTML), `container` (folder hierarchy), `attachments`. |
| **Conversion** | HTML body → Markdown via `pandoc -f html -t commonmark` on Mac Studio. Attachments (images, PDFs, drawings exported as PNG) saved alongside the `.md` as `attachments/<note-id>/<filename>` and referenced inline as `![](attachments/...)` Markdown image syntax — Nextcloud Notes renders inline images. |
| **Destination** | **Nextcloud Notes** app on files VM (180). The Notes app stores each note as an `.md` file in a configured folder (default: `Notes/`). We write directly into `Notes/iCloud/<folder>/<note-name>.md` via WebDAV (same mechanism as Phase 2's drive sync). The Notes app picks them up automatically. |
| **Full-fidelity backup alongside** | We ALSO write a `.html` version of each note to `Files/iCloud-Notes-HTML/<folder>/<note-name>.html` via WebDAV. Two-tier mirror: `.md` is the readable/editable surface in Nextcloud Notes; `.html` is the lossless restore-source preserving Apple's exact format. Disk cost is negligible. |
| **One-way guarantee** | Architecture-level: the Notes.app on Mac Studio is never written to by our script (read-only AppleScript queries). The Markdown files we generate go via WebDAV PUT to Nextcloud, never back to Apple. iCloud is touched only via Apple's normal Notes.app sync — outside our process. |
| **Cadence** | `StartInterval: 1800` (30 min). Notes change less often than mail/calendar; 30 min lag is fine. |
| **State** | `~/Library/Logs/icloud-notes-sync/manifest.json` — keyed on Apple's `note-id` (UUID-like), value is `{modification_date, sha256_of_body}`. Diff against current to find adds/changes/deletes. |
| **Format fidelity** | **Lossy by design** in the Markdown view — Apple Notes has features Markdown can't represent (table formatting nuances, scribbles, document scans, locked notes). We preserve text + structure + attachments in the `.md`; we lose pixel-perfect layout. The `.html` companion fills the lossless-restore role. Acceptable trade: this is a sovereignty backup, not a replica. |
| **Auth** | Nextcloud app token (vault: `vault_nextcloud_apptoken_notes_sync`). New token per integration. |
| **Run host** | Mac Studio (only place AppleScript Notes API exists). |
| **Observability** | Same pattern as Bookmarks: Loki heartbeats, dashboard row, stale alert. |
| **Nextcloud app to install** | **Notes** (`notes`, official, AGPL). Markdown-based, file-backed in Files, mobile clients (iOS, Android), REST API. Browse + edit experience like Apple Notes minus the attachments-inline. |

**Steps:**
- [x] Notes app installed and REST v1 API reachable — 2026-05-08
- [x] ~~Generate Nextcloud app token; store as `vault_nextcloud_apptoken_notes_sync`~~ — V1 reuses the Reminders env file (same pattern as Bookmarks)
- [x] ~~AppleScript exporter~~ — abandoned. `osascript -e 'tell application "Notes" to count of notes'` times out at `-1712` (CloudKit-fetch hang). Replaced with direct SQLite read of NoteStore.sqlite + gzip+protobuf body decoder. `~/bin/icloud-notes-sync.{py,sh}` on Mac Studio.
- [x] ~~Install pandoc~~ — not needed. We extract plain text from the protobuf bodies directly. Markdown rendering of attribute_runs (bold, italic, lists) deferred as Phase 2 work; V1 ships text-only.
- [x] Initial bulk: 260 notes pushed to Nextcloud Notes in 123s (171 new + 6 updated + 83 unchanged + 0 errors)
- [x] launchd plist `com.mineracks.icloud-notes-sync.plist` with WatchPaths on `~/Library/Group Containers/group.com.apple.notes/Container_v1/Stores` + 6h `StartInterval` safety net
- [ ] **Carry-forward**: Sanity gate (refuse if note count drops >10% vs prior run). Currently a malicious or buggy iCloud sync that drops half the local store would propagate the deletion to Nextcloud. Cheap to add (one count check pre-sync); not yet implemented.
- [x] File-provisioned alert `icloud-notes-sync-stale` (12h window, `noDataState: OK`) — `applications/icloud-sync/alerting.yml`
- [x] Dashboard row "📝  Notes (Apple) — iCloud → Nextcloud Notes" added
- [ ] Runbook addition under `applications/icloud-sync/README.md`

**Why not Joplin** (locked in 2026-05-07 with user): Joplin's sync model is bidirectional. Once configured, conflicts can propagate from Nextcloud back to Joplin's local state, and Joplin clients can write back to the same Nextcloud folder — a path that defeats the one-way semantic. The Nextcloud Notes app is genuinely one-directional from our perspective: we PUT files to a WebDAV folder, the Notes app reads them, no write-back path to Apple. Plus the user prefers a single Nextcloud surface for everything: the more we consolidate into Nextcloud, the simpler the recovery story.

The existing Joplin instance on the `notes` VM stays running for now (don't break it mid-flight); decide whether to retire it once Phase 6.3 is steady-state for ~30 days.

**Anti-patterns:**
- **Don't `tell application "Notes" to delete`** under any circumstance. The script should never instantiate write operations on Notes.app. Use AppleScript's `get` only.
- **Don't run while Notes.app is doing a heavy iCloud pull** (e.g., right after macOS update or first login on a new device). Notes.app's local cache may be incomplete; you'd export half a library. The sanity gate above (>10% drop = abort) covers this.
- **Don't try to be clever about attachments via SQLite** in v1. Stick with AppleScript's `attachments` property even if it's slow. Switch later only if a specific note class (e.g., scribbles) demands it.

#### Nextcloud apps to install (summary)

| App | App ID | Phase | Install command |
|---|---|---|---|
| **Tasks** | `tasks` | 6.1 | `sudo docker exec -u www-data nextcloud_web_1 php occ app:install tasks` |
| **Bookmarks** | `bookmarks` | 6.2 | `sudo docker exec -u www-data nextcloud_web_1 php occ app:install bookmarks` |
| **Notes** | `notes` | 6.3 | `sudo docker exec -u www-data nextcloud_web_1 php occ app:install notes` |

All three are official Nextcloud apps (GPL or AGPL), well-maintained, file/CalDAV/REST-backed (data lives in your Nextcloud, no opaque vendor lock).

#### Vault additions across Phase 6

| Key | Phase | Purpose |
|---|---|---|
| `vault_nextcloud_apptoken_bookmarks_sync` | 6.2 | Per-integration token for Mac Studio → Nextcloud Bookmarks REST. New token (per-integration revocation principle from Phase 5). |
| `vault_nextcloud_apptoken_notes_sync` | 6.3 | Per-integration token for Mac Studio → Nextcloud Notes WebDAV. |
| (none) | 6.1 | Reuses Phase 5's `vault_apple_id_app_password_dav` and `vault_nextcloud_apptoken_dav`. |

#### Order of execution

1. **Phase 6.1** first (~2h work). Smallest delta, biggest immediate win — Reminders visible in Nextcloud within an afternoon.
2. **Phase 6.2** next (~6h work). Self-contained — doesn't touch Phase 5 infrastructure. Adds a useful new surface (Floccus on iOS).
3. **Phase 6.3** last (~12h work). The lossy/hybrid one. Ship the AppleScript-only path first, instrument it well, decide later whether SQLite parsing is needed for a particular note class.

### ✅ Phase 7: Health Data — COMPLETE 2026-05-10 (streaming + historical backfill, end-to-end live)

**Status (2026-05-10 12:00 AEST):** Live at `https://health.example.com/`. Historical backfill: 8.14M HealthKit rows across 44 InfluxDB measurements + 47 SQLite tables (2.1 GB archive). Live streaming: iPhone Health Auto Export hourly automation POSTing to the bearer-authed `/ingest` endpoint, dual-writing to both stores. End-to-end iPhone-to-Grafana validated. See "What was built" + "Today's gotchas" below for the operational story.



**What:** Continuous self-hosted mirror of Apple Health data — every HealthKit sample (heart rate, steps, sleep, workouts, ECG, GPX, etc.) streams from iPhone to a dedicated **standalone** `health-mirror` VM as soon as it's recorded, plus a one-time backfill of all historical data via Apple's manual export. Visualisation, archive, and ingestion live on the SAME VM (single-function host pattern), with `https://health.example.com/` as the entry point.

**Why streaming + historical (not just one or the other):**
- Apple's manual "Export All Health Data" button dumps the *full* multi-GB history every time (no incremental mode) — extremely slow + impractical to repeat. Used **once** for the backfill, never again.
- HealthKit is the most locked-down iCloud service — there's no first-party HTTP API. The only practical streaming path is the **Health Auto Export** iOS app (~$5 one-time), which uses HealthKit's app-level read APIs and POSTs JSON deltas to a configurable webhook on whatever cadence you set. Granted permission once; runs invisibly in the background thereafter; payloads are KB-MB instead of multi-GB.
- Backfill seeds historical context (years of trends) in InfluxDB + SQLite; streaming keeps it fresh.

**Why standalone VM (not consolidated into logs VM):**
- Health data is medical-grade-sensitive; deserves its own auth boundary, network isolation, and PBS backup namespace.
- Single-function pattern already established across mineracks (`mail-mirror`, `cashu`, `lnvault`, `meet`, `calendar`, etc.) — `health-mirror` fits the convention.
- Blast radius: a runaway query or storage exhaustion on health data shouldn't take down the central observability/Loki stack.
- Self-contained makes per-host PBS backup + restore drills clean.

**Why iCloud Drive → Nextcloud as belt-and-braces:**
- Health Auto Export can ALSO drop a daily JSON dump into a chosen iCloud Drive folder. That folder is mirrored to Nextcloud via Phase 2's existing `rclone-documents-sync.sh` (when Documents is back on Nextcloud-only post-Phase 2.5, this still works for the new `iCloud-Drive/health/` subdir).
- So even if `health-mirror` VM is destroyed AND Health Auto Export disappears from the App Store one day, the Nextcloud-side daily JSON files remain a recoverable archive.
- Two paths simultaneously, near-zero marginal cost.

| | |
|---|---|
| **Source** | iPhone (Health Auto Export iOS app, paid one-time ~$5). Reads HealthKit deltas every cadence cycle, POSTs JSON. Background-task driven; no manual interaction after setup. |
| **Streaming destination** | New `health-mirror` VM. FastAPI ingester at `https://health.example.com/ingest` (Cloudflare Tunnel + bearer-token auth). Receives JSON, dual-writes to (a) **InfluxDB v2** for time-series + Grafana viz, (b) **SQLite** for archive + Datasette browsing. |
| **Backfill destination** | Same `health-mirror` VM. One-time: tap "Export All Health Data" on iPhone → save to iCloud Drive → propagates to Nextcloud → manually sftp the `export.zip` to `health-mirror`. Run `healthkit-to-sqlite export.zip /var/lib/health-mirror/archive.db` to seed the SQLite archive, then a small Python script reads the SQLite + writes equivalent records into InfluxDB so historical dashboards work day one. |
| **Belt-and-braces** | Health Auto Export configured to ALSO drop a daily aggregated JSON file into iCloud Drive `iCloud-Drive/health-export/YYYY-MM-DD.json`. Phase 2's mirror auto-copies it into Nextcloud. Even if `health-mirror` VM disappears, the Nextcloud-side history remains. |
| **Visualisation** | **Grafana** on the same VM, datasource = local InfluxDB. Dashboards: heart rate trends, step daily/weekly, sleep score, workout summaries, VO2 max, body composition. **Datasette** also on the same VM, serving the SQLite archive at `/datasette/` for ad-hoc SQL queries + GPX map rendering. |
| **One-way guarantee** | Architecture-level. The ingester only accepts POST writes; never modifies anything iPhone-side. iPhone HealthKit is touched only via Apple's normal frameworks (read-only by Health Auto Export). InfluxDB + SQLite are write-only from the ingester's perspective. |
| **Auth** | Tailscale + Cloudflare Access for human dashboards (`https://health.example.com/`); bearer-token-in-header for the ingest endpoint (iPhone POST, can't do CF Access from a background task). Vault: `vault_health_ingest_bearer_token`, `vault_influxdb_admin_password`, `vault_grafana_admin_password_health` (separate from the logs VM Grafana). |
| **Cadence** | Streaming: configurable on iPhone (recommend hourly batches + workout-end / sleep-end event triggers). Backfill: one-shot. Belt-and-braces JSON drop: daily. |
| **Observability** | Per-POST Loki heartbeat from the ingester (`{job="syslog", host="health-mirror", unit="health-ingest"}`) with `event=accepted samples=N elapsed=Ns` or `event=failed reason=...`. Sentinel rule `health-stream-stale` — fires if no `accepted` event in 6h (matches default hourly cadence with margin). |

**Host: dedicated `health-mirror` VM (single-function, standalone)**

Provisioning spec:
- Clone from the Ubuntu 24.04 template (VMID 9000)
- 4 GB RAM, 2 vCPUs (FastAPI + InfluxDB + Grafana fit; Datasette is light)
- 32 GB root disk on `mineracks-storage-pve` (shared NFS — per memory `vm_storage_pattern`)
- ~80 GB second data disk on `mineracks-storage-pve` mounted at `/var/lib/health-mirror/` (room for 5+ years of HealthKit data + InfluxDB compaction headroom + 6 months of daily JSON drops)
- Tailscale-joined (auto via vault auth key, `--ssh=false`)
- Promtail installed pointing at `logs:3100` so heartbeats flow to Loki under `{host="health-mirror"}`
- PBS backup schedule: daily, retain 30 days (longer than mail-mirror because health data has long-term value + slow growth)
- Docker-compose stack on the VM: `ingester` (FastAPI), `influxdb` (v2 OSS), `grafana`, `datasette`, `cloudflared` (tunnel for `health.example.com`)
- Hardened per `vps_hardening_pattern` (it's not external but the auth-boundary discipline still applies)

**Steps:**

*Provisioning + base stack (DONE 2026-05-09 evening):*
- [x] Provisioned `health-mirror` VM (VMID 781) on pve-01 — 4 GB / 2 cores / 32 + 80 GB on `mineracks-storage-pve`. Tailscale-joined as `health-mirror` at TAILNET_HOST.
- [x] Generated tonight's secrets and stashed in `~/health-mirror/.env` mode 600 on the VM (vault entries pending — see Phase 2.5-style concern about the 2026-05-09 vault shrinkage)
- [x] docker-compose.yml committed: ingester + InfluxDB v2 + Grafana 13.0.1 + Datasette + Caddy + cloudflared
- [x] FastAPI ingester `applications/health-mirror/ingester/main.py` — bearer-auth, dual-writes to InfluxDB + SQLite (`samples`, `live_workouts`, `raw_payloads` tables), emits Loki heartbeat per accepted POST
- [x] CF Tunnel `2a6442af-…` provisioned via API (no dashboard touches), DNS CNAME created, three CF Access apps wired (`/ingest` bypass + `/healthz` bypass + everything-else allow-mineracks-Google-SSO)
- [x] Grafana datasource `InfluxDB-Health` (Flux mode, default) added via `/api/datasources` POST
- [x] Initial dashboard `health-overview` (heart rate timeseries + body mass + 24h ingest counter) imported via `/api/dashboards/db`
- [x] Datasette container mounting the archive read-only at `/datasette/`

*iPhone integration (DONE 2026-05-10):*
- [x] Health Auto Export iOS app installed + HealthKit permissions granted (all categories)
- [x] Two automations created: "mineracks health-mirror" (Health Metrics) + "mineracks health-mirror-w…" (Workouts), both POSTing to `https://health.example.com/ingest` with `Authorization: Bearer <vault_health_ingest_bearer_token>` header
- [x] Cadence: Hourly + Batch Requests ON
- [x] Live-fire validated: ~125 MB JSON ingested via 5 successful POSTs (886,794 samples + 3 workouts) end-to-end through CF Tunnel → Caddy → ingester → InfluxDB + SQLite

*Historical backfill (DONE 2026-05-09):*
- [x] User had Apple's manual export.zip already on local disk (245 MB)
- [x] SCP'd to health-mirror, ran `healthkit-to-sqlite` → 2.1 GB `archive.db` with 47 tables (5M+ rows of samples + 2,996 workouts after a tolerant-import recovery from a UNIQUE-constraint bug in healthkit-to-sqlite for the workouts table)
- [x] Ran `seed-influxdb-from-sqlite.py` (after fixing schema mismatch — healthkit-to-sqlite uses `r<TypeName>` table names, not `HKQuantityTypeIdentifier*`) → **8,144,543 rows / 44 measurements** in InfluxDB. Years of historical context populating Grafana dashboards on day one.

*Observability + alert (DONE 2026-05-10):*
- [x] Sentinel alert `health-stream-stale` file-provisioned in `applications/icloud-sync/alerting.yml` — 6h window, `or vector(0)`, `noDataState: OK`, `keep_firing_for: 1h`. Fires if `{host=health-mirror, unit=health-ingest, event=accepted}` count over 6h drops below 1.
- [ ] **TODO:** Add a "🩺 Health" row to the icloud-sync Grafana dashboard with stat panels (Health: health, Samples ingested 24h, Workouts 24h, Activity timeseries, Recent events). Skipped this session because of dashboard JSON edit risk (memory `gitea_mcp_double_base64_bug`).
- [ ] **TODO:** Synthetic HTTP probe of `https://health.example.com/healthz` (different alert from `health-stream-stale` — that's at the data layer; this is at the tunnel layer). Add as a Sentinel synthetic monitor alongside the pay@ + ckpoolau ones.

*Documentation (DONE 2026-05-10):*
- [x] Runbook at `applications/health-mirror/README.md` (provisioning + deploy + recovery + the trailing-space gotcha)
- [x] Memory `phase7_health_streaming.md`
- [x] Memory `cf_access_path_mismatch_silent_redirect.md` — the URL-trailing-space iOS-success-on-302 trap that bit us 2026-05-10
- [x] Memory `macos_photos_silent_optimise_switch.md` — separate Phase 1 trap from 2026-05-09

**Today's gotchas (2026-05-09 to 2026-05-10):**

Three substantial traps surfaced during this build. All captured in dedicated memory entries; summary here for the runbook trail:

1. **healthkit-to-sqlite UNIQUE constraint bug on workouts table** — two `<Workout>` elements in some Apple exports hash to the same id. Crashes the import after 5M+ rows of perfectly good sample data are already in. Fix: standalone `import-workouts-tolerant.py` using `INSERT OR IGNORE` via iterparse.

2. **CF Access path-mismatch silent failure with iOS URLSession** — Trailing whitespace in the iPhone webhook URL → CF tries to match `/ingest%20` against the bypass app for `/ingest`, doesn't match, 302s to OIDC login → iOS follows redirect, gets 200 OK on the HTML login page → app reports "Uploaded data successfully" while origin sees nothing. Diagnose via CF GraphQL `httpRequestsAdaptiveGroups` (needs Zone:Analytics:Read on token, added 2026-05-10). Belt-and-braces: also bypass `/ingest%20`. See memory `cf_access_path_mismatch_silent_redirect.md`.

3. **Health Auto Export's workout payloads wrap numerics as `{qty: N, units: "..."}`** — my v1 ingester assumed scalar `{distance: 1.5}` and crashed with `TypeError: float() argument must be a string or a real number, not 'dict'`. Fixed via a `_scalar()` helper that unwraps the dict. (Health Metrics samples don't have this — only workouts.) See ingester `main.py:_scalar`.

**Anti-patterns to avoid:**

- **Don't expose the ingester URL without auth** — health data is medical-grade sensitive. Bearer token on every POST + Tailscale-only OR Cloudflare-Access-with-service-token-bypass. Plain HTTPS is not enough.
- **Don't mix Grafana with the logs VM** — separate auth boundary is the whole point of the standalone VM. The logs VM Grafana stays for ops/sync data; health VM Grafana stays for medical data; users authorised for one aren't automatically authorised for the other.
- **Don't write to InfluxDB without timestamp coordination during backfill** — the backfill script and the live stream could collide if backfill is run after streaming has been on for a while. Always backfill BEFORE enabling iPhone streaming, or use deterministic timestamps (HealthKit sample uuid) so re-writes are idempotent.
- **Don't skip the bulk import** — without it, Grafana dashboards show "data starts 2026-05-09" forever. The whole point of having years of HealthKit history is to surface trends; a streaming-only deployment loses that on day one.
- **Don't trust the iOS app's "schedule" alone** — iOS background task scheduling is best-effort. Set up Sentinel `health-stream-stale` to detect long gaps. The 6h window is intentionally tolerant of a missed background fire.
- **Don't put Datasette on the same Cloudflare Access app as Grafana** — different auth requirements (Datasette has its own session model). Separate sub-paths or sub-domains.

**What lives in vault:**

| Key | Purpose |
|---|---|
| `vault_health_ingest_bearer_token` | Authenticates iPhone POSTs to `https://health.example.com/ingest`. Long random token; rotate yearly. |
| `vault_influxdb_admin_password` | InfluxDB v2 admin password on the health-mirror VM. |
| `vault_grafana_admin_password_health` | Grafana admin on the health-mirror VM (separate from `vault_grafana_admin_password` on logs VM). |
| `vault_datasette_token` | Optional bearer for Datasette if we restrict it (otherwise CF Access alone gates it). |

**Order of execution / time estimate:**

1. **Day 1 — provision + base stack (~3h):** VM, docker-compose, ingester, InfluxDB, Grafana, Datasette, CF tunnel. Health endpoint up.
2. **Day 2 — iPhone integration (~30 min):** install app, grant permissions, configure POST URL + bearer + cadence. Verify with a fresh heart-rate sample.
3. **Day 3 — backfill (~2h, mostly waiting for export.zip):** Apple manual export, sftp to VM, run `healthkit-to-sqlite` + the InfluxDB seeder. Verify dashboards populate historical data.
4. **Day 4 — observability + polish (~1h):** Sentinel alert, dashboard rows, runbook, memory.

Total ~6.5h of active work spread across 3-4 days (mostly bound by waiting on Apple's slow first export).

### 📋 Phase 8: Messages — iMessage/SMS + Telegram + WhatsApp + Signal — PLANNED 2026-06-07

**What:** Self-hosted mirror of personal messaging across all four channels the operator actually uses — Apple iMessage + SMS/MMS (relayed from iPhone), Telegram, WhatsApp, and Signal — normalised into one searchable archive plus per-conversation exports browsable in Nextcloud. Completes the "everything in iCloud has a mineracks-owned copy" thesis: chat history is the one personal-data class the epic hasn't touched yet, and iMessage in particular *is* iCloud data (Messages-in-iCloud), so it belongs here.

**Why this fits the existing pattern (and why now):**
- iMessage uses the **exact Mac-as-adapter mechanism already proven in Phase 6.1.5** — the Mac Studio is signed into the same Apple ID, so `~/Library/Messages/chat.db` already holds the full iMessage + SMS history. A read-only SQLite parse → Nextcloud is structurally identical to the Notes phase. No new architectural risk.
- The four platforms span a wide difficulty range. Honest framing up front: **iMessage and Telegram are clean live `mirror`s; WhatsApp and Signal are fragile `archive`s by design** (both are local-first, E2E, with no first-party server history — Signal actively fights server-side export). Don't expect a tidy always-fresh mirror from the latter two; that's a property of those products, not a gap in our build.

**Architecture decision — target surface (Option A chosen):**

| Option | What | Verdict |
|---|---|---|
| **A — extractors → Datasette + Nextcloud** ✅ CHOSEN | Per-platform extractors normalise into one SQLite schema on a new `messages-mirror` VM, fronted by **Datasette** (already run on `health-mirror`, Phase 7) for unified full-text search across all four channels. Per-conversation HTML/Markdown exports dropped into Nextcloud `Messages/<platform>/<contact>/` for casual browsing — same idiom as Notes (Phase 6.3). | Stays 100% inside the existing Nextcloud-pane + single-function-VM + Datasette conventions. Archive-shaped, which is what this epic is. |
| **B — Matrix homeserver + mautrix bridges** ❌ NOT CHOSEN | Synapse/Conduit + `mautrix-telegram`/`-signal`/`-whatsapp`/`-imessage` gives all four *live* in one chat client (the self-hosted "Beeper"). The iMessage bridge needs a Mac — which we have. | Rejected for the *backup* epic: it's chat-client-shaped not archive-shaped, more moving parts, and sits outside the Nextcloud-pane philosophy. Worth revisiting separately if the operator wants a unified *live messaging client* (different goal). |

**Sequencing: easy-and-reliable first, fragile-and-local last** — 8.1 iMessage/SMS → 8.2 Telegram → 8.3 WhatsApp → 8.4 Signal.

#### ✅ Phase 8.1 — iMessage + SMS → Nextcloud (V1 COMPLETE 2026-06-08)

**Status:** Live. Full 12-year backfill (**4,135 conversations, 8,892 attachments, 9.1 GB**; iMessage + SMS, 2014→2026) is in Nextcloud at `Messages/iMessage/`, and a daily forward sync (`~/bin/imessage-mirror-sync.sh`, launchd @ 05:17) keeps it current via `rclone copy --checksum` deltas. Runbook: [`applications/icloud-sync/IMESSAGE-MIRROR.md`](../../applications/icloud-sync/IMESSAGE-MIRROR.md). V1 is Nextcloud-HTML-only (the shared Datasette store is deferred to when a second platform lands). Backfill was pushed via tar → single-file upload → server-side `occ files:scan` (per-file WebDAV was ~0.6 files/sec — 4+ h; the tarball path took ~15 min). Day-2: contact-name resolution (`--contacts-path`), Grafana row + Sentinel `imessage-mirror-stale` alert.

Original V1 design (as built):

| | |
|---|---|
| **Source** | `~/Library/Messages/chat.db` (SQLite) + `~/Library/Messages/Attachments/` on the Mac Studio. Already contains full iMessage **and** SMS/MMS history (green-bubble Text Message Forwarding from the iPhone) because the Mac is signed in with Messages-in-iCloud enabled. |
| **Extractor** | `imessage-exporter` (Rust, actively maintained — per-conversation HTML/TXT with inline attachments) for the Nextcloud export, **and/or** a small Python normaliser (`imessage_reader`-style) writing rows into the shared `messages-mirror` SQLite for Datasette. Read-only: parse a **copy** of `chat.db` (the live file is WAL-journalled + TCC-locked). |
| **Destination** | (a) `messages-mirror` VM SQLite `messages` table (`platform='imessage'`); (b) Nextcloud `Messages/iMessage/<contact>/` HTML export on files VM 180. Attachments to the VM data disk, **not** Nextcloud root. |
| **One-way guarantee** | Free — nothing writes back to `chat.db`; we parse a copy. Satisfies `strict_oneway_sync_semantics` without a `ReadOnlySession` wrapper. |
| **Cadence** | launchd `WatchPaths` on `chat.db-wal` (event-driven, ~30–60s) mirroring the Notes/Bookmarks event-driven pattern, OR `*/15` if WAL churn is too chatty. |
| **Gotchas** | (1) The extracting process needs **Full Disk Access** on the Mac (chat.db is in a TCC-protected path) — grant once to the launchd-invoked interpreter. (2) Copy chat.db + checkpoint the WAL before reading, or rows in the last write window are missed. (3) Attachments can be GBs — size the VM data disk accordingly. |

#### 📋 Phase 8.2 — Telegram → Datasette + Nextcloud (Easy, no Mac needed)

| | |
|---|---|
| **Source** | Telegram cloud (full server-side history, by design). Pulled via **Telethon** (Python/MTProto) user session — history + ongoing new messages + media — on a Linux VM. No Mac-adapter dependency, unlike every prior phase. |
| **Destination** | `messages-mirror` SQLite (`platform='telegram'`) + Nextcloud `Messages/Telegram/<chat>/`. |
| **One-way guarantee** | Read-only API calls (`iter_messages` / `download_media`); never sends. |
| **Cadence** | `*/15` cron incremental pull (track last-seen message id per chat); one-shot full backfill on first run. |
| **Vault** | `vault_telegram_api_id`, `vault_telegram_api_hash` (from my.telegram.org), `vault_telegram_session_string` (Telethon StringSession — guard like a password; it IS a logged-in session). |
| **Gotchas** | The StringSession is a full account credential — store encrypted in vault only, never in the repo. Telegram rate-limits aggressive history pulls (`FloodWaitError`) — Telethon handles backoff but seed slowly. |

#### 📋 Phase 8.3 — WhatsApp → Datasette + Nextcloud (Medium, pick a path)

| | |
|---|---|
| **Source — history path** | Android `msgstore.db.crypt15` local backup, decrypted with the 64-char account key via `wa-crypt-tools`. Most *complete* back-catalogue, but the key must be extracted from the device once (GrapheneOS-friendly). Periodic, not live → this is an **`archive`**. |
| **Source — live path (alt)** | A multi-device library (`whatsmeow` Go, or Baileys) registers as a **linked device** (scan QR once) and receives everything from link-time forward → a live forward-only **`mirror`**, but **no history before link time**. |
| **Recommended** | Do **both**: `whatsmeow` linked-device for the live stream + a one-time `crypt15` decrypt to seed history. Two sources, one normalised table. |
| **Destination** | `messages-mirror` SQLite (`platform='whatsapp'`) + Nextcloud `Messages/WhatsApp/<contact>/`. |
| **One-way guarantee** | Linked-device session is receive-only in our code (never call send APIs); crypt15 is an offline file decrypt. |
| **Gotchas** | The linked device counts against WhatsApp's device limit and can be remotely unlinked; alert if the session drops. crypt15 schema shifts between app versions — pin a known-good `wa-crypt-tools` version. **No clean always-fresh mirror exists** — set expectations accordingly. |
| **Vault** | `vault_whatsapp_backup_key` (64-char hex), `vault_whatsapp_whatsmeow_session` (if live path). |

#### 📋 Phase 8.4 — Signal → Datasette + Nextcloud (Hard, fragile by design)

| | |
|---|---|
| **Source — desktop path** | Signal Desktop's encrypted `sql/db.sqlite`, decrypted with the key Signal stows in the OS keychain — automated by `signal-export`. Works, but **schema changes between app versions break it**. |
| **Source — Android path (more complete)** | In-app encrypted backup + `signalbackup-tools` — fullest history, but a periodic *manual* export, not a stream. |
| **Destination** | `messages-mirror` SQLite (`platform='signal'`) + Nextcloud `Messages/Signal/<contact>/`. |
| **Nature** | **`archive`, not `mirror`.** Signal deliberately keeps no server-side history and resists export. Treat as a best-effort periodic snapshot; budget for breakage on Signal updates. |
| **Gotchas** | Desktop keychain decryption needs the Signal Desktop instance signed in on a host we control (could be the Mac Studio — same adapter idea). `signalbackup-tools` is the more robust path but manual. Pin tool versions; expect to chase schema drift. |
| **Vault** | `vault_signal_backup_passphrase` (Android backup 30-digit passphrase) if using the Android path. |

#### Host: dedicated `messages-mirror` VM (single-function, standalone)

Provisioning spec (mirrors `health-mirror`):
- Clone from Ubuntu 24.04 template (VMID 9000)
- 4 GB RAM, 2 vCPUs
- 32 GB root disk + ~100 GB data disk on `mineracks-storage-pve` (shared NFS per `vm_storage_pattern`) at `/var/lib/messages-mirror/` — chat attachments/media dominate the footprint
- Tailscale-joined (vault auth key, `--ssh=false`); Promtail → `logs:3100` under `{host="messages-mirror"}`
- PBS daily, retain 30 days
- Docker-compose: normaliser jobs + Datasette + Caddy + cloudflared (`messages.example.com`, CF Access Google-SSO operator-only, **separate auth app from health** per the Phase 7 anti-pattern)
- The **iMessage and (optionally) Signal-desktop extractors run ON the Mac Studio** (launchd) and push to the VM — same split as Phases 1/1.5/6; Telegram + WhatsApp-live run on the VM itself

#### Vault additions across Phase 8

| Key | Phase | Purpose |
|---|---|---|
| `vault_telegram_api_id` / `_api_hash` / `_session_string` | 8.2 | Telethon MTProto user session. Session string is a full account credential. |
| `vault_whatsapp_backup_key` | 8.3 | 64-char crypt15 decrypt key. |
| `vault_whatsapp_whatsmeow_session` | 8.3 | Linked-device session blob (live path). |
| `vault_signal_backup_passphrase` | 8.4 | Android encrypted-backup passphrase (Android path). |
| `vault_nextcloud_apptoken_messages_sync` | 8.x | Per-integration Nextcloud WebDAV token for the export drops (per-integration revocation, Phase 5 principle). |

#### Anti-patterns to avoid

- **Don't expect a live `mirror` from Signal or WhatsApp.** Both are local-first/E2E with no first-party history API. Label them `archive` in the runbook and in Grafana so future-you doesn't debug a "broken sync" that's actually working as designed.
- **Don't parse the live `chat.db`.** It's WAL-journalled and TCC-locked — copy + checkpoint first, or lose the last write window (same class of bug as the Notes NoteStore lock).
- **Don't commit any session string / backup key / passphrase to the repo.** Telethon sessions and WhatsApp keys are full account credentials — vault-only, encrypted. (Reinforces every `secrets_handling` lesson.)
- **Don't reuse the health VM's CF Access app.** Separate auth boundary per single-function VM (Phase 7 lesson) — and message content is just as sensitive as health data.
- **Don't bidirectional-sync anything.** No send APIs in our code; receive/parse only. (Phase 5 disaster lesson — architectural one-way, not by convention.)

#### Order of execution / time estimate

1. **8.1 iMessage/SMS (~half day):** smallest delta, reuses the Mac adapter + event-driven launchd pattern. Biggest immediate win — full message history searchable in an afternoon.
2. **8.2 Telegram (~half day):** self-contained, VM-only, clean API.
3. **8.3 WhatsApp (~1–1.5 days):** two-path (live + history seed), device-key extraction is the time sink.
4. **8.4 Signal (~1 day, ongoing fragility):** ship the most robust path, instrument it, accept periodic breakage.

`messages-mirror` VM provisioning + Datasette + Nextcloud export plumbing is shared setup (~half day) up front.

## What "done" looks like

When this epic is complete, every piece of data in iCloud has a live
(or regularly updated) copy on mineracks-owned infrastructure:

| iCloud Service | Self-hosted mirror | Sync frequency | Recovery time | Status |
|---|---|---|---|---|
| Photos (legacy + new) | Immich (full library) + Nextcloud (forward-only) | Real-time (minutes) | Immediate | ✅ DONE |
| iCloud Drive | Nextcloud | Real-time (minutes) | Immediate | ✅ DONE |
| Mail | mail-mirror VM (mbsync, Maildir, Dovecot RO IMAP) | Continuous (15m cron + flock) | Immediate | 🔄 IN PROGRESS (bulk INBOX still pulling) |
| Calendars | Nextcloud Calendar (CalDAV) | 5 min | Immediate | ✅ DONE |
| Contacts | Nextcloud Contacts (CardDAV) | 5 min | Immediate | ✅ DONE |
| Reminders (legacy CalDAV + CloudKit) | Nextcloud Tasks | 5 min (CalDAV) + 30–60s (CloudKit, event-driven) | Immediate | ✅ DONE |
| Bookmarks | Nextcloud Bookmarks | ~30s, event-driven (launchd WatchPaths on Safari plist) | Immediate | ✅ DONE |
| Notes | Nextcloud Notes (plain text bodies) | ~30s, event-driven (WatchPaths on NoteStore Group Container) | Immediate | ✅ DONE |
| Passwords | VaultWarden (shadow mirror) | Quarterly manual refresh | Immediate | ✅ DONE — iCloud Keychain stays authoritative; mirror has 810 items, GrapheneOS-accessible |
| Health | Local XML archive | Quarterly | Hours | 📋 PLANNED |
| Messages (iMessage/SMS + Telegram + WhatsApp + Signal) | Nextcloud `Messages/iMessage/` (HTML + media); `messages-mirror` VM + Datasette later | iMessage/SMS: daily (mirror); Telegram/WhatsApp/Signal: pending | Immediate (browse) | 🔄 IN PROGRESS (8.1 iMessage/SMS DONE 2026-06-08; 8.2–8.4 pending) |

**Epic status as of 2026-05-09 (early morning AEST):** **8 of 9 services** have a live self-hosted mirror. Mail is into subfolders after the bulk INBOX pull (~462k messages, ~75 GB on `mail-mirror`). Only **Health** remains planned. Phase 4 (Keychain → VaultWarden shadow mirror) shipped tonight along with hardening VaultWarden off Umbrel onto its own VM with full Litestream PITR + R2 off-site matching the rest of the fleet. The "small structured-data" cluster (Reminders / Bookmarks / Notes) shipped 2026-05-08 in one extended session and are now event-driven on Mac Studio.

If Apple locks the account tomorrow, the recovery plan is:
1. Photos → browse at `immich.example.com`
2. Documents → browse at `nextcloud.example.com`
3. Email → already on self-hosted mail
4. Passwords → log into VaultWarden
5. Calendar/Contacts → already in Nextcloud Calendar/Contacts at `nextcloud.example.com` (point any new device at the existing CalDAV/CardDAV endpoints)
6. Everything else → restore from periodic exports

**Total cost:** $0/month ongoing (self-hosted on existing infrastructure).
Replaces the need for iCloud+ subscription for backup purposes.

## Related

- [Immich runbook](../../applications/immich/README.md)
- [Nextcloud runbook](../../applications/nextcloud/README.md)
- [iCloud sync (Mac Studio scripts + Grafana dashboard + alerts)](../../applications/icloud-sync/README.md)
- [Sentinel monitoring](../../applications/sentinel/README.md)
- Memory: `nextcloud_cf_access_bypass_pattern` — explains why nextcloud.example.com has 13 Access apps (1 allow + 12 bypass) and why removing any of them breaks sync clients/OIDC

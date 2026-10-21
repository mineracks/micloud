# Phase 2.6 — Delta-Streaming Cache (thin local footprint)

**Status:** PoC **PROVEN end-to-end on live iCloud Drive data 2026-07-04.** Not yet
productionised. See "What's proven vs. what's left" at the bottom.

## Why

Today's pipelines (Phase 1 Immich, Phase 1.5 NC Photos, Phase 2 iCloud Drive) work by
holding a **full local copy** of the iCloud data on the Mac Studio bridge and then storing
a **second full copy** on Nextcloud/Immich. That's **2× the customer's iCloud allotment**:

- expensive on the bridge (an 848 GB Photos library + ~488 GB Drive = the whole 2 TB plan,
  mirrored locally),
- it fills local disk / iCloud quota, which is what silently trips macOS into
  "Optimise Mac Storage" and breaks the pipelines (see `macos_photos_silent_optimise_switch`),
- and it makes **mi-cloud as a product uneconomical**: provisioning 2× every customer's
  iCloud storage to supply one sovereign copy does not scale.

**Goal:** `1× sovereign copy on mineracks infra` + `a thin, self-bounding rolling cache`
on the bridge. Process only what **changed** (added / modified / deleted) since the last
confirmed write to Nextcloud/Immich.

## The constraint we discovered (2026-07-04)

There is **no CLI** to control iCloud file materialization/eviction on current macOS:

- `brctl download` / `brctl evict` — **removed** (only `status`/`monitor`/`dump` remain).
- `fileproviderctl` — **diagnostic only** (`dump`/`diagnose`/`check`/`repair`/`evaluate`/
  `obfuscate`). No evict/materialize.

But the **Foundation `NSFileManager` APIs still exist** and are fully functional via PyObjC
(system `/usr/bin/python3` has PyObjC; Homebrew python3 does **not**):

| Need | Primitive | Verified |
|---|---|---|
| Make a file dataless (free local bytes, keep cloud) | `evictUbiquitousItemAtURL:error:` | ✅ `ok=True` → `blocks=0`, `flags=dataless` |
| Materialize (download) on demand | `startDownloadingUbiquitousItemAtURL:error:` | ✅ `Current` in ~2 s → full `blocks` back |
| Detect dataless vs local (cheap, no download) | `NSURLUbiquitousItemDownloadingStatusKey` (`Current`/`NotDownloaded`), `IsUploadedKey`; or `stat` `blocks ≪ logical` / `ls -lO` `dataless` flag | ✅ |

Helper: `applications/icloud-sync/scripts/icloud-fp.py` (`status` / `evict` / `download`).

**This resolves the earlier worry that a thin cache was impossible on modern macOS.** The
CLI wrappers are gone, but the API gives *precise per-file* evict *and* materialize.

## Documents pipeline (one-way, thin-cache)

```
checkpoint manifest (path → mtime,size)
        │
   metadata-only scan (find/stat — does NOT materialize dataless files) ── cheap, O(files) but no downloads
        │
        ▼ diff vs manifest
   ┌──────────────┬───────────────────────────────┐
   │ added/mod    │ deleted                        │
   ▼              ▼                                 
 materialize   soft-delete: rclone move NC copy →   
 (download)    nextcloud:.trash/deltasync/<date>/   ← never touch iCloud; recoverable
   → verify Current
   → rclone copyto → Nextcloud (one-way)
   → evict (blocks→0)             ← local footprint stays ~0
        │
   commit checkpoint ONLY after all forwards confirmed  ← crash-safe: re-do a batch, never skip
```

Key properties:
- **rclone never blind-reads a placeholder.** We materialize + verify first, then
  `rclone copyto` explicit paths. That structurally eliminates the
  `resource deadlock avoided` class of failures we hit on dataless files.
- **Metadata scan doesn't materialize.** `stat`/`find` read inode metadata only — verified
  the delta scan runs entirely against dataless placeholders without downloading them.
- **Manifest** is the checkpoint (path, mtime, size — later: content hash). Idempotent.

PoC: `applications/icloud-sync/scripts/delta-sync-poc.sh`.

### Proven on live data (2026-07-04)

| Run | Action | Result |
|---|---|---|
| 1 | fresh manifest, 2 files | `added=2` → both materialized→forwarded→**evicted (blocks=0)**; Nextcloud has both |
| 2 | no changes | `added=0 deleted=0` (idempotent — no redundant re-sync) |
| 3 | add `test3`, delete `test2` | `added=1 deleted=1` → `test3` synced+evicted; `test2` soft-deleted to `.trash/deltasync/2026-07-04/` |

End state each run: **local footprint `blocks=0`** (dataless placeholders), **Nextcloud = full
1× copy**, iCloud untouched.

## Photos pipeline (same shape, different tool)

Photos isn't a plain file tree, so the delta + materialize primitive is **osxphotos** (already
installed, 0.75.9):

```
osxphotos export --added-after <checkpoint> --download-missing  → delta originals only
      → immich-cli upload  +  rclone → Nextcloud
      → advance export cursor
```

`--download-missing` *is* the on-demand materialize for Photos (it drives Photos.app to fetch
evicted originals for just the delta). This means **Photos can move to Optimise Mac Storage and
stay thin** — the current breakage isn't "Optimise is incompatible", it's that today's reader
(`osxphotos export` over `originals/`) assumes a full copy. Change the reader to
`--added-after --download-missing` and the constraint disappears.

`--download-missing` *is* the on-demand materialize for Photos (it drives Photos.app to fetch
evicted originals for just the delta). Primitives confirmed present in osxphotos 0.75.9:
`--added-after`, `--download-missing`, `--only-new`, `--update`.

**Event-driven shape** (mirrors the Documents daemon): a WatchPaths/FSEvents trigger on the Photos
library DB (`.photoslibrary/database/`) → debounced `osxphotos export --added-after <checkpoint>
--download-missing` → `immich-cli upload` + `rclone → Nextcloud` → advance the export cursor. (The
existing Phase 1/1.5 jobs already WatchPath the library — reuse that trigger.)

**Eviction caveat — Photos is coarser than iCloud Drive.** There is **no per-file evict API** for
Photos library originals (unlike `evictUbiquitousItemAtURL:` for iCloud Drive). The thin cache
therefore relies on **Photos' own "Optimise Mac Storage" auto-eviction** (macOS-managed, under disk
pressure) — `--download-missing` materialises the delta transiently and Photos re-evicts on its own.
So the Documents-style *precise* evict-after-forward isn't available; a small-disk bridge is what
keeps the Photos cache thin.

### ✅ RESOLVED — abandoned the SSD, fresh library on internal + Optimise, forwarder LIVE (2026-07-04)

The cloudphotod "wedge" turned out to be the **failing external SSD all along** — even repaired,
cloudphotod stayed idle on it. Rather than wait 3 weeks for an in-person reboot, the operator's pivot
(remote, no reboot): **abandon the SSD and start Photos fresh on internal storage with Optimise** —
internal has ample room (430 GB) because Optimise keeps only a working-set local.

- **New library created on the internal disk** (`~/Pictures/Photos Library.photoslibrary`), set as
  System Photo Library, **iCloud Photos + Optimise Mac Storage** enabled (all via screen-share GUI —
  no reboot). SSD unmounted + retired.
- **cloudphotod immediately synced it** — 23% CPU, library growing, thousands of assets (vs 0% wedged
  on the SSD). Proof it was the disk, never the setup. `0` I/O errors on the internal disk.
- **Gotcha:** unmounting the SSD *before* the library-switch finished made photolibraryd storm
  ~4000 `6922 I/O errors/sec` on the dead path (huge beachball). Fix: `killall -9 photolibraryd`
  → it respawned clean on the new library. **Do the switch first, unmount after.**
- **Optimise thin-cache validated:** `osxphotos export --download-missing` on the fresh library
  reports `missing:0` — it materialises dataless originals on demand, exactly as designed.

**Deployed** (`e1f817e`): `applications/icloud-sync/scripts/photo-delta-sync.sh` +
`com.mineracks.photo-delta-sync` (hourly, 2-day buffer) + `com.mineracks.photo-delta-sync-mopup`
(weekly, 21-day). osxphotos `--from-date --download-missing` → `immich upload` + rclone Nextcloud →
delete temp (thin). The old Download-Originals forwarders (`immich-photo-sync`,
`nextcloud-photo-sync`) are disabled (they read `originals/` directly, break on Optimise). Monitoring
(`mac-icloud-auth-emitter.sh`, watchdog) repointed off the dead SSD path onto the internal library.

## Reliability engineering (so it's a process, not a hack)

- **Strict one-way, enforced structurally** — forwarders are upload-only (`rclone copyto`,
  `immich-cli upload`); no code path can PUT/DELETE back to iCloud. (Rule:
  `strict_oneway_sync_semantics`.)
- **Soft-delete only** — deletes go to a dated `nextcloud:.trash/deltasync/<date>/`; a backup
  must not hard-delete just because the source did. (Matches existing `--backup-dir` behaviour.)
- **Checkpoint-after-confirm** — never advance the manifest past an unconfirmed write.
- **Reconciliation safety net** — a periodic (e.g. weekly) *metadata-only* full manifest diff to
  catch anything the real-time delta missed. Mandatory once FSEvents drives the delta
  (FSEvents can drop events on unmount/overload).
- **Dead-letter list** — files that fail to materialize N times get parked + alerted, never
  silently skipped.
- **Observability** — per-batch heartbeat to Loki/Sentinel
  (`files, bytes, materialize_failures, checkpoint_age`); alert on checkpoint staleness — the
  detector that would have caught the silent-Optimise "idle 0-added" failures.

## Scaling economics (the point)

Per customer: **1× sovereign copy on mineracks infra** (unavoidable — that *is* the product)
**+ a thin, self-bounding local cache** on a small-disk bridge. No 2× provisioning. The bridge
is the per-customer unit (one signed-in macOS instance per iCloud account), but its **disk can
be tiny** — evict-after-forward keeps the working set at ~0, and a small disk forces macOS's own
Optimise to stay aggressive as a backstop. Small-disk bridge = economical mi-cloud.

## What's proven vs. what's left

**Proven (PoC, 2026-07-04):** the two API primitives (evict + on-demand materialize), the
metadata-only delta scan against dataless placeholders, materialize→forward→evict, delta
detection for add/modify/delete, idempotent no-op runs, soft-delete, and that Nextcloud ends up
with a full copy while local stays `blocks=0`.

**Left to build for production:**
1. **Real-time delta** — replace the full metadata scan with an FSEvents-since-eventID watcher
   (no `fswatch` installed → small Swift/PyObjC `FSEventStream` helper, or `brew install fswatch`),
   with the metadata scan retained as the weekly reconciliation net.
2. **Materialize reliability at volume** — batch size, timeouts, retries, throttle/backoff
   against iCloud, dead-letter. Prove against thousands of evicted files, not two.
3. **Manifest → SQLite** (path, mtime, size, content-hash, `nc_confirmed_at`) for scale +
   crash-safety.
4. **Observability + Sentinel alerts** as above.
5. **Photos variant** wired through osxphotos `--added-after --download-missing` → Immich + NC.
6. Package as a launchd job under `applications/icloud-sync/`, one per customer bridge.

## Production build — Documents (2026-07-04)

`applications/icloud-sync/scripts/icloud-delta-sync.py` — the productionised version:
SQLite manifest, in-process PyObjC materialize/evict, retry + dead-letter, soft-delete,
Loki heartbeat, `flock`, and a **bootstrap that reconciles against what Nextcloud already
holds** (`rclone lsf -R`, size+path match) so it does **not** re-upload the corpus already
synced by Phase 2.

**Production finding — the metadata scan hangs on dataless package *bundles*.** The "cheap
metadata scan" premise holds for dataless *files* (`stat` returns logical size without
downloading) but **not for dataless package *directories*** — walking into an evicted
`.pvm`/`.app`/`.photoslibrary` etc. makes the FileProvider try to serve the listing and
**stalls** (the same `resource deadlock` that broke the old rclone). On the live `~/Documents`
tree the walk flew through 42k files then wedged inside a dataless `Windows 7 Boot Camp.pvm`.

Fixes, both in the script:
1. **Exclude package bundles** from the file-by-file walk (`.pvm .pvmp .vmwarevm .utm
   .sparsebundle .imovielibrary .fcpbundle .logicx .app .photoslibrary …`) — they are opaque
   huge units you'd never sync file-by-file anyway. With these pruned the full scan of
   **135,333 files / 13,415 dirs completes in ~19 s** (154 bundles skipped).
2. **Scan-timeout guard** (`SCAN_TIMEOUT`, `SIGALRM`) — attempted, but **does not work**: a
   Python `SIGALRM` cannot interrupt a *hung C syscall* (a never-returning `readdir` on a
   dataless dir), so the handler never runs and the process hangs forever, its `flock`
   blocking every future run. Superseded — see the blocker below.

> Package bundles are therefore **out of scope for file-level delta sync** — if specific bundles
> (a VM image, a Photos library) need backing up they need opaque-unit handling
> (materialize-whole → rclone the dir → evict), a separate path.

### ⚠️ BLOCKER — the full-tree scan is a dead end on this tree (deployed → reverted 2026-07-04)

After bundle-exclusion the scan completed cleanly *some* runs (~19 s) but **intermittently, and
sometimes persistently, hangs on a plain dataless directory listing** (confirmed hanging at
`ValuePRO/Video Demos/2011` even with a fresh `bird`). Same FileProvider deadlock class as the old
rclone. Because the `SIGALRM` guard can't kill a hung syscall, a stalled run blocks the job
indefinitely.

**End-to-end delta forwarding, materialize/evict, soft-delete, manifest, and Loki heartbeats all
verified working** (add `synced=1`, delete → NC `.trash`, `fails=0`) — the ONLY broken piece is
**change *detection* via `os.walk`**. So the job was deployed, verified on real deltas, then
**reverted**: `com.mineracks.rclone-documents-sync` (the working full-mirror) restored;
`com.mineracks.icloud-delta-documents` unloaded (code + plist kept).

### ✅ RESOLVED — FSEvents change-source, deployed EVENT-DRIVEN (2026-07-04)

The fix: get changes from the **FSEvents stream** (changed paths since a persisted event-ID),
which **never `readdir`s the tree** — so it structurally cannot wedge on a dataless dir. Each
changed path is `stat`'d individually (fast on dataless *files*; only dataless *dir listing*
hangs). Validated on the live tree: FSEvents captures create/modify/delete with flags + a
resumable `latest_event_id`, and **replay-since-a-stored-checkpoint** catches changes that
happened while the job wasn't running.

Then, per the operator, made it **event-driven instead of a timer** — a change on the iCloud
filesystem is mirrored to Nextcloud **within seconds**, not on a 20-min tick:

- **`--watch` daemon** (`com.mineracks.icloud-delta-documents`, launchd `KeepAlive`+`RunAtLoad`):
  a long-running FSEvents stream (1s debounce) → materialize → `rclone copyto` → evict, per change.
  Verified: **create → Nextcloud in ~8s, delete → soft-deleted in seconds.** Stable (same pid,
  0 restarts over a 150s undisturbed window). Callback is fully try/except-wrapped so a bad path
  can't unwind the run loop. Checkpoint = max processed event-id, persisted per batch → a restart
  replays the gap with no loss.
- **Bootstrap** needs NO scan at all: set the checkpoint to the current FSEvents id; the Phase-2
  corpus is already in Nextcloud and FSEvents carries every change from here on.
- **`--reconcile` weekly mop-up** (`com.mineracks.icloud-delta-documents-reconcile`, Sun 03:17):
  the robust child-process scan (SIGKILL-timeout — SIGKILL *does* kill a hung-syscall process,
  verified) cross-checked against the full Nextcloud listing, for anything FSEvents dropped
  (Mac asleep/off, kernel/user event drops).
- The old full-mirror `com.mineracks.rclone-documents-sync` is retired (`.disabled`).

The materialize→forward→evict→manifest→heartbeat machinery was reused as-is; only the
change-source was swapped (scan → FSEvents). **Phase 2.6 for Documents is live and event-driven.**

## Artifacts

- `applications/icloud-sync/scripts/icloud-fp.py` — evict/materialize/status helper (PyObjC).
- `applications/icloud-sync/scripts/delta-sync-poc.sh` — the proven delta-sync PoC.
- `applications/icloud-sync/scripts/icloud-delta-sync.py` — production Documents delta-sync.

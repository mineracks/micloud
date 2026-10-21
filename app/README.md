# micloud — native macOS app

The native Swift/SwiftUI implementation of micloud, replacing the `agent/` scripts (now the
**reference spec**) with sandbox-legal Apple frameworks. Two distributions from one codebase, exactly
as `ROADMAP.md` Phase 2 lays out:

- **App Store build** — sandboxed, native, discoverable, transaction-capable. Point-and-click.
- **Power build** — the unsandboxed full-power agent, notarized + open source, for self-host maximalists.

## Architecture

```
app/
  MicloudKit/            Swift package — the pure-logic core (NO Apple-UI/sandbox code).
                         Config model, SyncSource contract, telemetry/health. Builds + smoke-tests
                         under Command Line Tools (no full Xcode). Shared by BOTH builds.
  micloud/    (todo)     SwiftUI UI app: onboarding coach + dashboard; LSUIElement menu-bar presence.
  SyncHelper/ (todo)     SMAppService sandboxed agent — the always-on engine. Native observers
                         (PhotoKit / EventKit / FSEvents / NSMetadataQuery) → URLSession upload to
                         Nextcloud (WebDAV) + Immich (API) → evict. XPC to the UI app for the dashboard.
  probes/     (todo)     The T1–T4 sandbox device tests (run FIRST, per the spike).
```

The sync sources are framework-native and event-driven; one-way is enforced (iCloud is never written)
and deletes are soft (dated trash on the target). See `docs/design/mas-background-sync-spike.md` for
the SMAppService + sandbox reasoning, and `phase-2.6-delta-streaming-cache.md` for the thin-cache engine.

## Build prerequisites

| | |
|---|---|
| **Swift toolchain** | ✅ Swift 6.3 (Command Line Tools) — enough to build/smoke `MicloudKit`. |
| **Full Xcode** | ⚠️ **Required** for the app/helper: signed sandboxed `.app`, entitlements, `SMAppService`, running T1–T4, and archiving for the App Store. Not installable via CLT. |
| **Apple Developer** | Apple Development identity present (team `YOUR_TEAM_ID`). Paid Program ($99/yr) needed for App Store distribution + notarization of the power build. |
| **iCloud** | A test Mac signed into iCloud (this MacBook is) — needed for the T1/T2 Drive tests. |

```bash
# core only (works today, no Xcode):
cd app/MicloudKit && swift build && swift run Smoke
# full app (once Xcode is installed):  xcodegen generate && xcodebuild ...
```

## Milestones

- **M0 — scaffold + sandbox de-risk.** MicloudKit core ✅. Then the **T1–T4 probes** (T1: force-evict an
  iCloud Drive file under sandbox — the thin-cache linchpin) **before writing the engine**. If T1/T2 wall
  off, those capabilities live only in the power build (the two-distribution model absorbs it).
- **M1 — dashboard UI.** SwiftUI dashboard (matches `web/dashboard-mockup.html`) reading local `HealthSnapshot`.
- **M2 — first source end-to-end.** iCloud Drive → Nextcloud via NSMetadataQuery + URLSession/WebDAV.
- **M3 — remaining sources.** PhotoKit→Immich, EventKit/Contacts, Notes/Bookmarks.
- **M4 — onboarding wizard** (the coach, `agent/onboarding/`).
- **M5 — SMAppService helper + background** (App Nap `beginActivity`, XPC telemetry).
- **M6 — MAS packaging:** entitlements, "Data Not Collected" privacy label, ASO (Phase 2c), Stripe (2b).

## Status

`MicloudKit` core scaffolded and green under CLT (config / contract / telemetry). **T1 sandbox probe:
PASSED** (2026-07-08, on the Studio) — a sandboxed app can force-evict an iCloud Drive file to a dataless
placeholder and re-download it on demand, so the **Drive thin-cache ships in the App Store build**, not
just the power build (`app/probes/t1-drive-evict/`, see `docs/design/mas-background-sync-spike.md`). Next:
the native sync engine. **T2 (whole-Drive change watching): PASSED** too (2026-07-08) — a sandboxed
`FSEventStream` on a user-granted iCloud Drive folder fires for changes made on another device (within
iCloud's sync latency), reporting only changed paths (no tree walk); NSMetadataQuery needs an iCloud
entitlement we lack ad-hoc, so FSEvents is the mechanism. **The whole Drive half of the engine is now
proven under the sandbox.** Remaining probes: T3 (background + App Nap), T4 (SMAppService round-trip).

**PhotosSource (M3 — PhotoKit) PROVEN end-to-end (2026-07-12), on this MacBook.** With the Studio
down, the build+test moved here — the probe apps sign with `swiftc` + ad-hoc `codesign` (CLT only), and
this MacBook is on the same iCloud, so nothing about the native work needed the Studio. `app/probes/photos-app/`
requests Photos access under the sandbox (`personal-information.photos-library` entitlement +
`NSPhotoLibraryUsageDescription` + user consent), fetches each asset's **original** via
`PHAssetResourceManager` (`isNetworkAccessAllowed` so iCloud-Optimized originals download on demand), and
WebDAV-uploads to the drill. Live run: authorized (status 3), 180 079-image library, **newest 5 originals
(HEIC + PNG) uploaded and verified byte-exact on the drill** (`Photos/micloud-test/`), and
`PHPhotoLibraryChangeObserver` fired throughout — so **the "watch" half works for Photos too**. TCC gotcha
banked: a sandboxed app must be launched via **LaunchServices (`open`)** to be its own responsible process
and get the Photos prompt; direct-exec from a shell attributes the request to Terminal and is auto-denied.
Photos eviction stays system-managed ("Optimize Mac Storage") by design — no per-asset evict step. ⇒ **two
real sources now proven under the App Store sandbox** (Drive + Photos).

**Photos → Immich AND Nextcloud (fan-out) PROVEN (2026-07-12).** MicloudKit gained `ImmichClient` (URLSession
multipart `POST /api/assets`, `x-api-key`, server-side checksum dedup) and a `PhotoTarget` protocol that
**both** `NextcloudWebDAV` (via `NextcloudPhotoTarget`) and `ImmichClient` satisfy — so `PhotosSource` fans
out to one or both per `MicloudConfig.PhotosComponent.toImmich/toNextcloud`. `ImmichClient` was live-verified
by `ImmichLiveTest` (CLT executable) against a disposable Immich drill (LXC 997 on pve-03,
`http://LAN_HOST:2283`): auth → upload `created` → re-upload `duplicate`. Then `photos-app` was rebuilt to
**fetch each original once and push it to both targets**: a live run mirrored the newest photos and they
landed **byte-exact on Nextcloud AND Immich** (3 full round-trips before the run was cut short). This is the
user's stated ideal — stream photos to Immich and/or Nextcloud Photos — **realized, and entirely off the
Studio** (pure `URLSession` + CLT).

**M1 — dashboard UI DONE (2026-07-12).** `MicloudKit` gained the engine layer — `HealthStore` (thread-safe
`HealthSnapshot` holder with `observe`/`cancel` + a `recentEvents` ring for the Live feed) and `SyncEngine`
(source lifecycle: `start`/`stop`/`reconcileAll`, isolating a failing source as `.error`). `app/micloud/`
is the first real app: `MicloudApp` (@main SwiftUI) wires a live `PhotosSource` (a `SyncSource` wrapping the
proven PhotoKit fan-out) through `SyncEngine` into a `DashboardModel` that subscribes to the `HealthStore`;
`Dashboard.swift` renders the mockup (navy/orange, "storage you own" hero, 7 source tiles with status pills,
Live feed, Sync-now). **Live-confirmed**: Photos tile Syncing→Up-to-date, header pill Protected·all-healthy,
hero "10 mirrored this session" (5×2 targets), Live feed streaming real `IMG_… → immich/nextcloud: created`;
the other six sources render as honest disabled tiles. Built with `swiftc -parse-as-library` + ad-hoc
`codesign` — **no full Xcode** (the app compiles the MicloudKit sources in via `kit/`, so no `import MicloudKit`).

**DriveSource (M2 — first real source) STARTED.** `MicloudKit` now has `NextcloudWebDAV` (URLSession
PUT / MKCOL / MOVE, correct path percent-encoding, CLT-verified) and the `DriveSource` orchestrator wiring
**watch (T2) → materialise-if-dataless (T1) → WebDAV upload → evict (T1) → heartbeat**, one-way with
soft-delete to a dated trash — all compiling under CLT. **WebDAV upload LIVE-VERIFIED** (2026-07-08) against a disposable TurnKey Nextcloud drill (VM 999 on
pve-03, reachable over the tailnet): `NextcloudWebDAV` did MKCOL → ensureParents → PUT (path with spaces)
→ MOVE end-to-end, files persisted on disk (`Sources/DriveLiveTest`). So **all three DriveSource pieces —
T1 evict, T2 watch, WebDAV upload — are individually proven.** **Full DriveSource PROVEN end-to-end (2026-07-08)** in a sandboxed app on the Studio
(`app/probes/drive-app/`): a file dropped in iCloud Drive on the MacBook was **watched → materialised →
uploaded to the drill Nextcloud** (correct size 1400 B, correct content) **→ evicted to dataless locally**
(diskBlocks 0). The live run surfaced + we fixed two real bugs — an evict→FSEvent re-upload loop and a
0-byte overwrite — with a per-path dedup (inFlight + a quiet window) and a hard "never upload a dataless
file" guard. **Known refinement:** iCloud can take >60 s to deliver a new file cross-Mac, so a first pass
can skip it as still-dataless; the `reconcile()` mop-up timer (currently a TODO) should re-scan + retry
those. **The DriveSource is now a working product component**, not a probe.

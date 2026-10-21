# Spike — Mac App Store background-sync feasibility

**Question:** Can a **sandboxed Mac App Store app** run micloud's **always-on, near-real-time** sync —
or does "always-on" require a privileged launchd daemon (which the App Store forbids)?

## Verdict — feasible; background execution is NOT the blocker

A sandboxed MAS app can be an always-on background sync agent. Apple provides a sandbox-compatible,
App-Store-allowed mechanism for a persistent background helper. The genuine remaining unknowns are a
handful of **sandbox data-access behaviours** (forced eviction + whole-Drive change watching) — small,
concrete device tests, not architectural showstoppers. **Green-light the native build; run the 4 tests
below (T1 first) before writing the real sync engine.**

## Resolved from Apple's documented behaviour

### Always-on background execution — solved, two MAS-legal mechanisms
- **`SMAppService.agent`** — a MAS app bundles a **sandboxed LaunchAgent** in
  `Contents/Library/LaunchAgents/` and registers it via `SMAppService`. Apple: *"SMAppLaunch is
  compatible with the App Sandbox … if you sandbox your app you must sandbox your agent"* — the helper
  is signed with `com.apple.security.app-sandbox` + `com.apple.security.application-groups` (for XPC),
  and must NOT use `com.apple.security.inherit` (the system runs it, not the app). This helper runs in
  the user session independent of the UI window — the **daemon-equivalent without a privileged daemon**.
- **`SMAppService.loginItem` + `LSUIElement`** — launches at login, runs as a menu-bar/agent process
  (no dock icon). The standard shape for continuous-sync menu-bar apps.

macOS (unlike iOS) **does not suspend running apps** — a resident agent keeps receiving change events in
real time. The one throttle to manage is **App Nap**: hold a `ProcessInfo.beginActivity` assertion while
syncing so the agent stays responsive. So the "always-on Mac mirror" premise holds on a MAS build,
provided the target Mac has an active user session (a dedicated always-on Mac / auto-login VM does by
definition — which is exactly the deployment target).

### Data access under the sandbox — mostly resolved, entitlement-gated
- **Network** → Nextcloud WebDAV + Immich API: fine (`com.apple.security.network.client`).
- **Photos** → PhotoKit: `PHPhotoLibraryChangeObserver` (real-time change events) + `PHAssetResourceManager`
  (fetch originals) work sandboxed with the Photos entitlement.
- **Calendars / Contacts / Reminders** → EventKit / Contacts, with entitlements + user consent.
- **iCloud Drive** → *"from a sandboxed app, iCloud Drive is like any other external volume; access is
  mediated by sandbox extensions"* — read + upload work once the user grants the folder (security-scoped).

## The residual unknowns — the actual device spike (½–1 day, minimal sandboxed Xcode project)

**T1 — Force-evict an iCloud Drive file under sandbox (the thin-cache linchpin, highest value).**
Grant a folder in iCloud Drive; on a downloaded file call `FileManager.evictUbiquitousItem(at:)`, confirm
it goes dataless (`stat` blocks → 0), then `startDownloadingUbiquitousItem(at:)` and confirm it
re-materialises. *If this fails sandboxed, the Drive thin-cache degrades to system-managed — or lives only
in the power build.*

> **RESULT (2026-07-08): PASSED ✅.** Verified on the Studio (Xcode 26.5) with an ad-hoc-signed sandboxed
> AppKit probe (`app/probes/t1-drive-evict/`). Under `com.apple.security.app-sandbox` +
> `files.user-selected.read-write`: the security-scoped grant worked; `evictUbiquitousItem(at:)` took a
> downloaded iCloud Drive file **dataless instantly** (`diskBytes` 4096 → 0, `notDownloaded`);
> `startDownloadingUbiquitousItem(at:)` **re-materialised it in ~1s** (`diskBytes` 0 → 4096, `current`).
> **The Drive thin-cache works in the App Store build** — no need to relegate it to the power build. No
> Apple Developer account needed for the test (user-selected file access requires no provisioning profile).

**T2 — Watch the user's whole iCloud Drive for changes from the sandbox.**
Compare `NSMetadataQuery` (ubiquitous scope) vs an `FSEventStream` on the security-scoped granted folder.
Confirm change events for files created/edited on *other* devices arrive within seconds — **without listing
the tree** (the dataless-directory readdir-deadlock lesson from the current agent still applies).

> **RESULT (2026-07-08): PASSED ✅ (via FSEvents).** `app/probes/t2-drive-watch/`, sandboxed + ad-hoc signed
> on the Studio. An `FSEventStream` on the user-granted iCloud Drive folder **fired for files created/edited
> on another device** (driven from the MacBook, same Apple ID) **~12–18s later** — that delay is iCloud's
> download latency, not FSEvents. iCloud materialises a synced-down file by an atomic **rename**, so changes
> surface as `renamed` events; **only the changed paths are reported — no tree walk**, dodging the
> readdir-deadlock. **NSMetadataQuery returned 0 items and never fired** (ad-hoc has no iCloud-container
> entitlement) — so **FSEvents is the mechanism** (same as the power build); a paid-account build could
> revisit NSMetadataQuery but doesn't need to. With T1, the **whole Drive half of the engine is proven
> under the App Store sandbox.**

**T3 — Background continuity + App Nap over hours.**
Run as an `LSUIElement` login item; leave it idle/occluded for hours; confirm PhotoKit/EventKit/FSEvents
notifications still fire promptly with a `beginActivity` assertion held. Measure energy impact.

**T4 — `SMAppService` agent round-trip.**
Bundle a trivial sandboxed LaunchAgent, `SMAppService.agent.register()`, confirm it survives logout/login
and talks to the UI app over XPC (app-group). Confirms the daemon-equivalent end-to-end for MAS.

## Known limitation — accept, don't fight
**Photos eviction is system-managed.** "Optimize Mac Storage" decides the local photo cache; there is no
per-asset evict API (true today, too). So the Photos thin-cache relies on the system in *both* builds —
already how it works, and acceptable.

## Recommended architecture (post-spike)
- **UI app** (SwiftUI, universal arm64+x86_64): onboarding coach + dashboard; `LSUIElement` menu-bar presence.
- **Sync helper** (`SMAppService` sandboxed agent): the always-on engine — event-driven observers per source
  (PhotoKit / EventKit / FSEvents / NSMetadataQuery) → native `URLSession` upload to Nextcloud/Immich →
  evict (pending T1). XPC to the UI app to feed the dashboard's local telemetry.
- **Power build** (non-MAS, notarized, open source): if T1/T2 hit sandbox walls, the unsandboxed build keeps
  the full thin-cache/eviction behaviour for self-host maximalists. This is exactly the **two-distribution
  model** already in the ROADMAP — so even a worst-case spike result doesn't break the plan; it just sharpens
  which capabilities live in which build.

## Sources
- Apple Developer Forums — [SMAppService agents & the App Sandbox / App Store](https://developer.apple.com/forums/thread/743395)
- Apple Developer Forums — [Sandboxed app access to iCloud Drive via sandbox extensions](https://developer.apple.com/forums/thread/727902)
- Apple — [iCloud File Management: `evictUbiquitousItemAtURL:` / `startDownloadingUbiquitousItemAtURL:`](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)
- [LSUIElement background/agent apps](https://cocoadev.github.io/LSUIElement/) · [building a menu-bar agent app](https://rderik.com/blog/understanding-a-few-concepts-of-macos-applications-by-building-an-agent-based-menu-bar-app/)

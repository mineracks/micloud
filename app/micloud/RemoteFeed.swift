import Foundation
import SwiftUI

/// Monitor mode: this Mac renders the dashboard ANOTHER Mac publishes to the shared Nextcloud
/// (`micloud/status.json`, see `Coordinator.statusLoop`). Nothing on this Mac is read or synced — the feed
/// just drives the same `DashboardModel` + `BackfillModel` the local dashboard uses, so the laptop shows the
/// rack Mac's cards, bars, rates and live log exactly as that Mac draws them, at the cadence it publishes.
@MainActor
final class RemoteFeed {
    private let model: DashboardModel
    private let backfill: BackfillModel
    private let dav: NextcloudWebDAV
    private var lastGenerated: Date?

    init?(model: DashboardModel, backfill: BackfillModel) {
        let inst = InstallStore.load()
        guard inst.isMonitor, let s = inst.nextcloudURL, let base = URL(string: s),
              let u = inst.nextcloudUser, let p = SovereignStore.secret("nextcloud:\(u)") else { return nil }
        let filesRoot = base.appendingPathComponent("remote.php/dav/files").appendingPathComponent(u)
        dav = NextcloudWebDAV(filesRoot: filesRoot, username: u, appPassword: p,
                              session: URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil))
        self.model = model; self.backfill = backfill
        model.readOnly = true
    }

    /// Poll forever. The report says how often the publisher is writing; poll at that rate (floor 5 s).
    func run() async {
        var every: Double = 5
        while true {
            if let data = try? await dav.fetch(StatusReport.remotePath), let r = try? StatusReport.decode(data) {
                apply(r)
                every = max(5, r.refreshSeconds ?? 30)
            } else if model.watchedHost == nil {
                model.remoteNote = "waiting"
            }
            try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
    }

    private func apply(_ r: StatusReport) {
        model.watchedHost = r.host
        model.remoteGeneratedAt = r.generatedAt
        model.remoteNote = r.isFresh ? nil : "offline"
        model.snapshot = r.snapshot
        model.enabled = Set(r.snapshot.heartbeats.filter { $0.value.status != .disabled }.map(\.key))
        if let ev = r.events { model.events = ev }
        if let a = r.activity { model.activity = a }
        var jobs: [SourceID: BackfillJob] = [:]
        let now = Date()
        for (id, lane) in r.lanes ?? [:] {
            // Carry the previous job so the stall clock (settled unchanged for 2 min) runs here as well.
            var j = backfill.jobs[id] ?? BackfillJob()
            // The publisher runs the stall clock and holds it while it reconciles (5b29036). Mirror its verdict:
            // a second clock here read "waiting" through every nine-minute reconcile after a relay restart.
            // A feed without the flag (older publisher) falls back to watching `settled` move.
            if let stalled = lane.stalled {
                j.lastProgressAt = stalled ? now.addingTimeInterval(-(BackfillJob.stallAfter + 1)) : now
            } else if lane.settled != j.progress.settled || j.lastProgressAt == nil { j.lastProgressAt = now }
            j.remoteETA = lane.stalled == true ? nil : lane.etaSeconds; j.remoteHasETA = true
            var p = BackfillProgress()
            p.total = lane.total; p.done = lane.done; p.skipped = lane.skipped; p.failed = lane.failed
            p.pending = lane.pending; p.inFlight = lane.inFlight; p.quarantined = lane.quarantined
            p.totalBytes = lane.totalBytes; p.confirmedBytes = lane.confirmedBytes; p.quarantinedBytes = lane.quarantinedBytes
            p.targets = lane.targets ?? []        // photos → "Nextcloud 97 % / Immich 99 %" rows, as the relay draws them
            p.kept = lane.kept ?? 0; p.deferred = lane.deferred
            j.progress = p; j.rate = lane.rate; j.itemRate = lane.itemRate; j.lastItem = lane.lastItem
            j.phase = BackfillJob.Phase(remote: lane.phase)
            jobs[id] = j
        }
        backfill.jobs = jobs
        model.mirroredToday = r.mirroredToday
        lastGenerated = r.generatedAt
    }
}

extension BackfillJob.Phase {
    init(remote: LaneReport.Phase) {
        switch remote {
        case .scanning: self = .scanning; case .transferring: self = .transferring; case .paused: self = .paused
        case .done: self = .done; case .blocked: self = .blocked; case .stopped: self = .stopped
        }
    }
}

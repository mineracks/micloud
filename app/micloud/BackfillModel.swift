import Foundation
import SwiftUI
import Network

/// Live state of a per-source backfill, for the dashboard panel + tile ring. Fed by `BackfillEngine.onProgress`.
struct BackfillJob: Equatable {
    static func == (a: BackfillJob, b: BackfillJob) -> Bool { a.progress == b.progress && a.rate == b.rate && a.lastItem == b.lastItem && a.phase == b.phase && a.capacity == b.capacity }
    enum Phase: Equatable { case scanning, transferring, paused, done, blocked, stopped }
    var progress = BackfillProgress()
    var rate: Double = 0                 // bytes/sec (EWMA from the engine)
    var itemRate: Double = 0             // items/sec (EWMA, measured here) — the honest ETA for many small files
    var itemSample: (at: Date, settled: Int)? = nil
    var lastProgressAt: Date? = nil      // when `settled` last moved — a lane that hasn't moved is stalled, not "244,099,924 h left"
    var itemsMeasured = 0                // settled items seen by the item-rate sampler; a rate off 3 reconcile ticks is noise
    var remoteETA: Double? = nil         // monitor mode: the publishing Mac's own estimate (nil = it had none)
    var remoteHasETA = false
    var lastItem = ""
    var phase: Phase = .scanning
    var capacity: CapacityReport?        // set when a target trips the 85% gate (tight / won't-fit)

    /// Byte-weighted fraction (confirmed + given-up) / total — reaches 1.0 when nothing's left to try.
    var fraction: Double {
        let d = progress.totalBytes
        guard d > 0 else { return phase == .done ? 1 : 0 }
        return min(1, Double(progress.confirmedBytes + progress.quarantinedBytes) / Double(d))
    }
    /// Bytes-based ETA (bandwidth-bound lanes) vs item-based ETA (round-trip-bound lanes: 34,000 small mails,
    /// or a sweep where most items are "already there" and move no bytes). Whichever is longer is the truth;
    /// whichever is measurable is better than "—".
    var etaSeconds: Double {
        // Nothing settled for two minutes → the rates are decaying EWMAs of a lane that is not moving. Their
        // tails are tiny-but-nonzero, which turns into an absurd ETA. Say "—" (stalled) instead.
        if let t = lastProgressAt, Date().timeIntervalSince(t) > Self.stallAfter { return Double.infinity }
        if remoteHasETA { return remoteETA ?? Double.infinity }
        let byBytes = rate > 0 ? Double(progress.calibratedRemainingBytes) / rate : Double.infinity
        let left = max(0, progress.total - progress.settled - progress.quarantined)
        // The item rate needs a real sample before it may set the estimate — otherwise a reconcile pass that
        // settles three items in a window reads as "505 h left" for 27,000 files.
        let byItems = itemRate > 0 && itemsMeasured >= Self.minItemsForRate ? Double(left) / itemRate : Double.infinity
        let eta: Double
        if byBytes.isFinite && byItems.isFinite { eta = max(byBytes, byItems) }
        else { eta = byBytes.isFinite ? byBytes : byItems }
        return eta > Self.etaCeiling ? Double.infinity : eta       // beyond a year is not an estimate
    }
    static let stallAfter: TimeInterval = 120
    static let minItemsForRate = 20
    static let etaCeiling: TimeInterval = 365 * 86400
    /// Transferring but nothing has settled for a while — the card says so rather than showing a frozen rate.
    var isStalled: Bool {
        guard phase == .transferring, let t = lastProgressAt else { return false }
        return Date().timeIntervalSince(t) > Self.stallAfter
    }
    var isActive: Bool { phase == .scanning || phase == .transferring }
    var isVisible: Bool { phase != .done || progress.hasUnreadable }   // keep 'done' up if there's a review
}

final class BackfillModel: ObservableObject {
    @Published var jobs: [SourceID: BackfillJob] = [:]
    @Published var onWiFi = false          // drives the "plug in Ethernet" speed tip
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Wi-Fi (and not also wired) → the tip applies; wired/other → no tip.
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            DispatchQueue.main.async { self?.onWiFi = wifi }
        }
        monitor.start(queue: DispatchQueue(label: "micloud.net"))
    }

    func update(_ id: SourceID, progress: BackfillProgress, rate: Double, item: String, stage: BackfillStage = .transferring) {
        DispatchQueue.main.async {
            var j = self.jobs[id] ?? BackfillJob()
            let now = Date()
            if stage == .preparing {
                // Enumerate + reconcile: nothing settles here by design (a 175,000-name listing takes minutes),
                // so the stall clock must not run — the Drive card read "waiting — nothing moved for 2 min" at
                // 100 % during every re-scan. And a reconcile that marks thousands "already there" in one tick
                // must not seed the item rate.
                j.progress = progress; j.rate = rate; j.lastItem = item
                j.lastProgressAt = now; j.itemSample = nil; j.itemRate = 0; j.itemsMeasured = 0
                if j.phase != .paused && j.phase != .stopped { j.phase = .scanning }
                self.jobs[id] = j
                return
            }
            if progress.settled != j.progress.settled || j.lastProgressAt == nil { j.lastProgressAt = now }
            j.progress = progress; j.rate = rate; j.lastItem = item
            if let s = j.itemSample {
                let dt = now.timeIntervalSince(s.at)
                if dt >= 3 {
                    j.itemsMeasured += max(0, progress.settled - s.settled)
                    let r = Double(max(0, progress.settled - s.settled)) / dt
                    j.itemRate = j.itemRate == 0 ? r : 0.3 * r + 0.7 * j.itemRate
                    j.itemSample = (now, progress.settled)
                }
            } else { j.itemSample = (now, progress.settled) }
            if j.phase != .paused && j.phase != .stopped {
                j.phase = progress.total == 0 ? .scanning : .transferring
            }
            self.jobs[id] = j
        }
    }
    func setPhase(_ id: SourceID, _ phase: BackfillJob.Phase) {
        DispatchQueue.main.async { var j = self.jobs[id] ?? BackfillJob(); j.phase = phase; self.jobs[id] = j }
    }
    func setCapacity(_ id: SourceID, _ report: CapacityReport?) {
        DispatchQueue.main.async { var j = self.jobs[id] ?? BackfillJob(); j.capacity = report; self.jobs[id] = j }
    }
    func clear(_ id: SourceID) { DispatchQueue.main.async { self.jobs[id] = nil } }

    var anyActive: Bool { jobs.values.contains { $0.isActive } }
}

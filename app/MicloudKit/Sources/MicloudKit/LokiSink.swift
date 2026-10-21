import Foundation

/// Forwards every `Heartbeat` to a Loki push endpoint so a fleet (our own relay, or a turnkey customer)
/// gets the same staleness alerting the Mac Studio scripts had — without a single script.
///
/// Stream labels: `job=micloud host=<hostLabel> instance=<instance> source=<SourceID>`.
/// Line: `event=<idle|synced|syncing|failed|stale|alive> status=<raw> pending=N items=N last="…"`.
/// `event` is derived from the status TRANSITION so alert rules can count successes:
///   syncing → healthy  = `synced`     (a pass that moved something just finished)
///   healthy → healthy  = `idle`       (nothing to do — still a success)
///   error              = `failed`
///   stale              = `stale`
///   the periodic ticker (`tick()`)    = `alive` for every enabled source
/// Push failures are swallowed (telemetry must never affect mirroring); the last error is kept for the UI.
public final class LokiSink: @unchecked Sendable {
    public let url: URL
    public let labels: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var lastStatus: [SourceID: SourceStatus] = [:]
    private var lastSeen: [SourceID: Heartbeat] = [:]
    public private(set) var lastError: String?

    public init(url: URL, hostLabel: String, instance: String = "default", session: URLSession = .shared) {
        self.url = url
        self.labels = ["job": "micloud", "host": hostLabel, "instance": instance]
        self.session = session
    }

    public func push(_ hb: Heartbeat) {
        lock.lock()
        let prev = lastStatus[hb.source]
        lastStatus[hb.source] = hb.status
        if hb.status != .disabled { lastSeen[hb.source] = hb } else { lastSeen[hb.source] = nil }
        lock.unlock()
        let event: String
        switch hb.status {
        case .healthy:  event = (prev == .syncing) ? "synced" : "idle"
        case .syncing:  event = "syncing"
        case .error:    event = "failed"
        case .stale:    event = "stale"
        case .disabled: return
        }
        send(hb, event: event)
    }

    /// Emit `alive` for every enabled source — call every few minutes from the app so a wedged
    /// process (no heartbeats at all) is distinguishable from a quiet one.
    public func tick() {
        lock.lock(); let seen = Array(lastSeen.values); lock.unlock()
        for hb in seen { send(hb, event: "alive") }
    }

    private func send(_ hb: Heartbeat, event: String) {
        var stream = labels; stream["source"] = hb.source.rawValue
        var line = "event=\(event) status=\(hb.status.rawValue) pending=\(hb.pendingCount)"
        if let n = hb.itemCount { line += " items=\(n)" }
        if let b = hb.cacheBytes { line += " cache_bytes=\(b)" }
        if let it = hb.lastItem { line += " last=\"\(it.replacingOccurrences(of: "\"", with: "'").prefix(200))\"" }
        let ns = String(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        let body: [String: Any] = ["streams": [["stream": stream, "values": [[ns, line]]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data; req.timeoutInterval = 10
        session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            self.lock.lock()
            if let err { self.lastError = err.localizedDescription }
            else if code >= 300 { self.lastError = "loki HTTP \(code)" }
            else { self.lastError = nil }
            self.lock.unlock()
        }.resume()
    }
}

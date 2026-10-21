import Foundation
import MicloudKit

// Publish a StatusReport to a real Nextcloud, read it back, decode, verify — the round-trip the iOS
// companion depends on. Reads NEXTCLOUD_URL/USER/PASS from env.

let env = ProcessInfo.processInfo.environment
guard let urlStr = env["NEXTCLOUD_URL"], let root = URL(string: urlStr),
      let user = env["NEXTCLOUD_USER"], let pass = env["NEXTCLOUD_PASS"] else {
    print("Set NEXTCLOUD_URL, NEXTCLOUD_USER, NEXTCLOUD_PASS."); exit(2)
}
final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) } else { h(.performDefaultHandling, nil) }
    }
}
let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
let dav = NextcloudWebDAV(filesRoot: root, username: user, appPassword: pass, session: session)

// a representative snapshot
var snap = HealthSnapshot()
snap.record(Heartbeat(source: .photos, status: .healthy, lastItem: "IMG_1660.HEIC", itemCount: 180_079))
snap.record(Heartbeat(source: .documents, status: .syncing, lastItem: "report.pdf", pendingCount: 3))
snap.record(Heartbeat(source: .contacts, status: .healthy, itemCount: 2_982))

do {
    let report = StatusReport(host: "Example Mac Studio", appVersion: "0.1", snapshot: snap)
    print("PUBLISH micloud/status.json (overall=\(report.overall)) …")
    try await report.publish(via: dav)
    print("  OK ✅")

    // read it back
    var r = URLRequest(url: dav.url(for: StatusReport.remotePath))
    r.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let (data, resp) = try await session.data(for: r)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { print("❌ GET failed: \((resp as? HTTPURLResponse)?.statusCode ?? -1)"); exit(1) }
    let back = try StatusReport.decode(data)
    print("READ BACK: host=\(back.host) overall=\(back.overall) sources=\(back.snapshot.heartbeats.count)")
    let ok = back.host == report.host && back.overall == report.overall
        && back.snapshot.heartbeats[.photos]?.itemCount == 180_079
        && back.snapshot.heartbeats[.documents]?.status == .syncing
    print(ok ? "\n✅ StatusReport round-trips via Nextcloud — the iOS companion can read this." : "\n❌ mismatch")
    exit(ok ? 0 : 1)
} catch {
    print("❌ FAILED: \(error)"); exit(1)
}

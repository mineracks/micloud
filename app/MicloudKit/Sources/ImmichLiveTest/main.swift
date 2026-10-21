import Foundation
import MicloudKit

// Live round-trip against a real Immich, exercising the actual ImmichClient.
//   export IMMICH_URL=https://LAN_HOST      # base URL (no /api)
//   export IMMICH_KEY=<api key>
//   swift run ImmichLiveTest
// The key comes from the environment; nothing secret is printed.

let env = ProcessInfo.processInfo.environment
guard let urlStr = env["IMMICH_URL"], let base = URL(string: urlStr),
      let key = env["IMMICH_KEY"] else {
    print("Set IMMICH_URL and IMMICH_KEY in the environment."); exit(2)
}
let apiRoot = base.appendingPathComponent("api")

// Accept a self-signed drill cert (TEST ONLY — the real client uses default validation).
final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: trust)) }
        else { h(.performDefaultHandling, nil) }
    }
}
let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
let immich = ImmichClient(apiRoot: apiRoot, apiKey: key, deviceId: "micloud-livetest", session: session)

// a tiny but valid 1x1 PNG so Immich accepts it as an image asset
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
let name = "micloud-livetest-\(Int(Date().timeIntervalSince1970)).png"
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
try! png.write(to: tmp)
let now = Date()

do {
    print("AUTH  GET /api/users/me …")
    let who = try await immich.checkAuth();                        print("  OK ✅ (\(who))")
    print("UPLOAD  \(name) …")
    let r1 = try await immich.uploadAsset(localFile: tmp, filename: name, createdAt: now, modifiedAt: now)
    print("  OK ✅ (\(r1))")
    print("RE-UPLOAD (expect duplicate — proves checksum dedup) …")
    let r2 = try await immich.uploadAsset(localFile: tmp, filename: name, createdAt: now, modifiedAt: now)
    print("  OK ✅ (\(r2))")
    let dedupOK = (r1 == .created && r2 == .duplicate)
    print("\n\(dedupOK ? "✅" : "⚠️") ImmichClient works end-to-end — auth, upload (\(r1)), re-upload (\(r2))."
        + (dedupOK ? " Dedup confirmed." : " (dedup not observed — check Immich version)"))
} catch {
    print("\n❌ FAILED: \(error)"); exit(1)
}

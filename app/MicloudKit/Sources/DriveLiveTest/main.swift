import Foundation
import MicloudKit

// Live WebDAV round-trip against a real Nextcloud, exercising the actual NextcloudWebDAV client.
//   source nc-drill-creds.env               # sets NEXTCLOUD_USER / NEXTCLOUD_PASS
//   export NEXTCLOUD_URL=https://DRILL_HOST/remote.php/dav/files/admin
//   swift run DriveLiveTest
// Credentials come from the environment; nothing is printed.

let env = ProcessInfo.processInfo.environment
guard let urlStr = env["NEXTCLOUD_URL"], let root = URL(string: urlStr),
      let user = env["NEXTCLOUD_USER"], let pass = env["NEXTCLOUD_PASS"] else {
    print("Set NEXTCLOUD_URL, NEXTCLOUD_USER, NEXTCLOUD_PASS in the environment."); exit(2)
}

// Accept the drill's self-signed cert (TEST ONLY — the real client uses default validation).
final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: trust)) }
        else { h(.performDefaultHandling, nil) }
    }
}
let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
let dav = NextcloudWebDAV(filesRoot: root, username: user, appPassword: pass, session: session)

// a small local file to upload
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-live-\(Int(Date().timeIntervalSince1970)).txt")
try! "hello from the micloud DriveSource live test\n".write(to: tmp, atomically: true, encoding: .utf8)

let dir = "micloud-drill-test"
let remote = "\(dir)/sub folder/live.txt"   // spaces on purpose — exercises path encoding
let moved  = "\(dir)/moved live.txt"

do {
    print("MKCOL  \(dir) …");                    try await dav.makeCollection(dir);            print("  OK ✅")
    print("PARENTS+PUT  \(remote) …");           try await dav.ensureParents(of: remote)
                                                 try await dav.upload(localFile: tmp, to: remote); print("  OK ✅")
    print("MOVE  \(remote) -> \(moved) …");       try await dav.move(remote, to: moved);        print("  OK ✅")
    print("\n✅ NextcloudWebDAV works end-to-end against the drill — MKCOL, ensureParents, PUT (with spaces), MOVE.")
} catch {
    print("\n❌ FAILED: \(error)"); exit(1)
}

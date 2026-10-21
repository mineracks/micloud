import AppKit
import Photos
import Foundation

// ── micloud PhotosApp — Photos → Nextcloud (validates PhotoKit under the sandbox) ───────────────
// New surface: the photo library, via PhotoKit (the sandbox-legal replacement for osxphotos).
//   • request Photos access (entitlement + NSPhotoLibraryUsageDescription + user consent)
//   • enumerate assets, fetch each ORIGINAL via PHAssetResourceManager (iCloud download allowed)
//   • upload to Nextcloud (reusing NextcloudWebDAV) into a folder its Photos app indexes
//   • register a PHPhotoLibraryChangeObserver to prove change detection ("watch" for Photos)
// No evict step — Photos eviction is system-managed ("Optimize Mac Storage"), by design.
// Creds from env; self-signed drill cert via a test-only permissive URLSession.
// Log → container: ~/Library/Containers/com.mineracks.micloud.photosapp/Data/micloud-photosapp.log
// For the test, uploads at most TEST_LIMIT originals so we don't push the whole library.

let TEST_LIMIT = 5
let resultPath = NSHomeDirectory() + "/micloud-photosapp.log"
let logQ = DispatchQueue(label: "log")
var logText = ""
func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    logQ.sync {
        logText += "[\(ts)] \(s)\n"
        FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
        try? logText.write(toFile: resultPath, atomically: true, encoding: .utf8)
    }
}

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) } else { h(.performDefaultHandling, nil) }
    }
}

final class Delegate: NSObject, NSApplicationDelegate, PHPhotoLibraryChangeObserver {
    var targets: [PhotoTarget] = []
    let remotePhotosPath = "Photos/micloud-test"

    func applicationDidFinishLaunching(_ note: Notification) {
        log("=== micloud PhotosApp — Photos → Nextcloud + Immich (PhotoTarget fan-out) ===")
        log("home (container ⇒ sandboxed): \(NSHomeDirectory())")
        let env = ProcessInfo.processInfo.environment
        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)

        // Nextcloud target (optional): NEXTCLOUD_URL/USER/PASS
        if let urlStr = env["NEXTCLOUD_URL"], let root = URL(string: urlStr),
           let user = env["NEXTCLOUD_USER"], let pass = env["NEXTCLOUD_PASS"] {
            let dav = NextcloudWebDAV(filesRoot: root, username: user, appPassword: pass, session: session)
            targets.append(NextcloudPhotoTarget(dav: dav, photosPath: remotePhotosPath))
            log("target +nextcloud: \(root.absoluteString) (\(user)) → \(remotePhotosPath)")
        }
        // Immich target (optional): IMMICH_URL + IMMICH_KEY
        if let urlStr = env["IMMICH_URL"], let base = URL(string: urlStr), let key = env["IMMICH_KEY"] {
            let immich = ImmichClient(apiRoot: base.appendingPathComponent("api"),
                                      apiKey: key, deviceId: "micloud-macbook", session: session)
            targets.append(immich)
            log("target +immich: \(base.absoluteString)/api")
        }
        guard !targets.isEmpty else {
            log("NO targets — set NEXTCLOUD_URL/USER/PASS and/or IMMICH_URL/IMMICH_KEY"); return
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            log("Photos authorization: \(status.rawValue) (\(status == .authorized ? "authorized ✅" : status == .limited ? "limited" : "denied/notDetermined"))")
            guard let self, status == .authorized || status == .limited else { log("no Photos access — cannot continue"); return }
            PHPhotoLibrary.shared().register(self)
            log("PHPhotoLibraryChangeObserver registered (watch for new photos)")
            Task { await self.initialUpload() }
        }
    }

    func initialUpload() async {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        log("library: \(assets.count) images — uploading the newest \(min(assets.count, TEST_LIMIT)) as a test")
        for i in 0..<min(assets.count, TEST_LIMIT) {
            await mirror(assets.object(at: i))
        }
        log(">>> initial test upload complete. Now add a photo to the library to test the change observer.")
    }

    /// Fetch the asset's ORIGINAL once, then fan it out to every configured target.
    func mirror(_ asset: PHAsset) async {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo }) ?? resources.first else {
            log("no resource for asset \(asset.localIdentifier)"); return
        }
        let filename = resource.originalFilename
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? created
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + filename)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ropts = PHAssetResourceRequestOptions(); ropts.isNetworkAccessAllowed = true  // fetch from iCloud if needed
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: tmp, options: ropts) { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size]) as? Int) ?? -1
            log("fetched original \(filename) (\(bytes) bytes) → \(targets.count) target(s)")
            for t in targets {
                do {
                    let r = try await t.uploadPhoto(localFile: tmp, filename: filename,
                                                    createdAt: created, modifiedAt: modified)
                    log("  → \(t.label): \(r)")
                } catch {
                    log("  → \(t.label): FAILED \(error)")
                }
            }
        } catch {
            log("FAILED \(filename): \(error)")
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        log("photoLibraryDidChange ✅ — the change observer fired (new/edited/removed photos detected)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()

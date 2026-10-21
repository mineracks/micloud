// swift-tools-version:5.9
import PackageDescription

// MicloudKit — the pure-logic core shared by both distributions:
//   • the sandboxed Mac App Store app (SwiftUI UI + SMAppService sync helper)
//   • the notarized open-source "power build"
// It deliberately holds NO Apple-framework/UI/sandbox code, so it compiles + unit-tests
// with the Command Line Tools toolchain (no full Xcode) and stays platform-portable.
let package = Package(
    name: "MicloudKit",
    platforms: [.macOS(.v13)],            // macOS 13+ (SMAppService)
    products: [
        .library(name: "MicloudKit", targets: ["MicloudKit"]),
    ],
    targets: [
        .target(name: "MicloudKit"),
        // XCTest tests — run under full Xcode (`swift test`). XCTest isn't in Command Line Tools.
        .testTarget(name: "MicloudKitTests", dependencies: ["MicloudKit"]),
        // A CLT-runnable smoke check of the same logic (`swift run Smoke`) — no Xcode needed.
        .executableTarget(name: "Smoke", dependencies: ["MicloudKit"]),
        // Live WebDAV round-trip against a real Nextcloud (reads NEXTCLOUD_URL/USER/PASS from env).
        .executableTarget(name: "DriveLiveTest", dependencies: ["MicloudKit"]),
        // Live Immich round-trip: auth + upload + dedup (reads IMMICH_URL/IMMICH_KEY from env).
        .executableTarget(name: "ImmichLiveTest", dependencies: ["MicloudKit"]),
        // Live status.json publish + read-back round-trip (what the iOS companion reads).
        .executableTarget(name: "StatusLiveTest", dependencies: ["MicloudKit"]),
        // Live backfill against a Nextcloud drill: capacity preflight + folder upload + poison quarantine + resume.
        .executableTarget(name: "BackfillLiveTest", dependencies: ["MicloudKit"]),
        // Issuing-side license signer (the checkout backend / Stripe+BTCPay webhook calls this).
        // Reads the Ed25519 private key from env MICLOUD_LICENSE_SK; never takes it on the command line.
        .executableTarget(name: "LicenseSign", dependencies: ["MicloudKit"]),
    ]
)

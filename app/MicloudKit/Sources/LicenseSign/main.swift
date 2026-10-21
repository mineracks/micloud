import Foundation
import MicloudKit

// micloud license signer — issuing side. The checkout backend (Stripe / BTCPay webhook) runs this to mint a
// Pro token after a successful payment. The Ed25519 private key comes from the environment (vault-injected),
// NEVER from the command line or a file in the repo.
//
//   MICLOUD_LICENSE_SK=<base64 private key> \
//     swift run LicenseSign --sub cust_abc123 --plan annual --days 365
//
//   --plan   monthly | annual | lifetime      (default: annual)
//   --days   validity in days; 0 = perpetual   (default: 365; lifetime implies 0)
//
// Prints the signed token to stdout. Verify locally with the embedded public key before shipping.

func arg(_ name: String, _ def: String? = nil) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--\(name)"), i + 1 < a.count { return a[i + 1] }
    return def
}

// --verify <token>: verify a token against the EMBEDDED public key and print its payload. Used to prove
// that an independent signer (e.g. the Python checkout backend) produces app-valid tokens.
if let token = arg("verify") {
    guard let p = License.verify(token) else {
        FileHandle.standardError.write(Data("INVALID: signature does not verify against the embedded public key\n".utf8))
        exit(1)
    }
    print("VALID sub=\(p.sub) edition=\(p.edition) plan=\(p.plan) valid=\(p.isValid())")
    exit(0)
}

guard let skB64 = ProcessInfo.processInfo.environment["MICLOUD_LICENSE_SK"], !skB64.isEmpty else {
    FileHandle.standardError.write(Data("error: set MICLOUD_LICENSE_SK (base64 Ed25519 private key) in the environment\n".utf8))
    exit(2)
}
guard let sub = arg("sub"), !sub.isEmpty else {
    FileHandle.standardError.write(Data("error: --sub <customer-reference> is required\n".utf8))
    exit(2)
}

let plan = arg("plan", "annual")!
let requestedDays = Int(arg("days", plan == "lifetime" ? "0" : "365")!) ?? 365
let now = Date()
let exp = requestedDays > 0 ? now.addingTimeInterval(Double(requestedDays) * 86400) : nil

let payload = LicensePayload(sub: sub, plan: plan, iat: now, exp: exp)
do {
    let token = try License.sign(payload, privateKeyBase64: skB64)
    // Self-check: verify against the EMBEDDED public key so we never emit a token the app would reject.
    guard License.verify(token) == payload else {
        FileHandle.standardError.write(Data("error: signed token failed embedded-public-key verification — wrong MICLOUD_LICENSE_SK?\n".utf8))
        exit(1)
    }
    let expStr = exp.map { ISO8601DateFormatter().string(from: $0) } ?? "perpetual"
    FileHandle.standardError.write(Data("issued pro/\(plan) for \(sub), expires \(expStr)\n".utf8))
    print(token)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

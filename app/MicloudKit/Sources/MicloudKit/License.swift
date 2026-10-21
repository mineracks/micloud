import Foundation
import CryptoKit

/// A micloud Pro license: a compact, **offline-verifiable** token that unlocks the Pro-edition tiles
/// (Notes, Bookmarks, Mail, Health). The checkout backend (Stripe / BTCPay webhook) signs it with an
/// Ed25519 private key; the app verifies it against the embedded public key — **no phone-home**, works
/// fully offline, and can't be forged without the private key.
///
/// Token format (JWT-ish, but Ed25519 not HMAC): `base64url(payloadJSON).base64url(signature)`, where the
/// signature is over the raw `base64url(payloadJSON)` bytes.
public struct LicensePayload: Codable, Equatable, Sendable {
    public var sub: String          // customer reference (opaque id or email) — who it's for
    public var edition: String      // "pro"
    public var plan: String         // "monthly" | "annual" | "lifetime"
    public var iat: Date            // issued-at
    public var exp: Date?           // expiry; nil = perpetual (e.g. lifetime)

    public init(sub: String, edition: String = "pro", plan: String, iat: Date, exp: Date? = nil) {
        self.sub = sub; self.edition = edition; self.plan = plan
        // Floor to whole seconds so the ISO8601 round-trip is exact (tokens are deterministic + `==`-comparable).
        self.iat = Self.floorToSecond(iat)
        self.exp = exp.map(Self.floorToSecond)
    }
    private static func floorToSecond(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }

    public func isValid(now: Date = Date()) -> Bool {
        guard edition == "pro" else { return false }
        if let exp { return now < exp }
        return true
    }
}

public enum License {
    /// The micloud license **public** key (Ed25519, base64). The matching private key lives only on the
    /// mineracks issuing backend (in the vault) — never in the app or this repo.
    public static let publicKeyBase64 = "VW2WmzJOl1GvDlWjMi6JHcHd8WHjb+z7Ehhqc+N68QI="

    /// Verify a token against `publicKeyBase64` and return its payload iff the signature checks out.
    /// (Expiry is a separate `isValid()` check, so the UI can distinguish "forged" from "expired".)
    public static func verify(_ rawToken: String, publicKeyBase64: String = publicKeyBase64) -> LicensePayload? {
        // Tolerate surrounding whitespace/newlines — a token stored from a file (the CLI `print`s a trailing
        // newline) or pasted with stray whitespace must still verify.
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = token.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let sig = b64urlDecode(String(parts[1])),
              let payloadData = b64urlDecode(String(parts[0])),
              let pkData = Data(base64Encoded: publicKeyBase64),
              let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkData),
              pk.isValidSignature(sig, for: Data(parts[0].utf8)),
              let payload = try? Self.decoder.decode(LicensePayload.self, from: payloadData)
        else { return nil }
        return payload
    }

    /// Sign a payload (issuing side — used by the license CLI / checkout backend, given the private key).
    public static func sign(_ payload: LicensePayload, privateKeyBase64: String) throws -> String {
        guard let skData = Data(base64Encoded: privateKeyBase64) else { throw LicenseError.badKey }
        let sk = try Curve25519.Signing.PrivateKey(rawRepresentation: skData)
        let body = b64urlEncode(try encoder.encode(payload))
        let sig = try sk.signature(for: Data(body.utf8))
        return body + "." + b64urlEncode(sig)
    }

    // ── JSON (ISO8601 dates) ──────────────────────────────────────────────────
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()

    // ── base64url (no padding) ─────────────────────────────────────────────────
    static func b64urlEncode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

public enum LicenseError: Error { case badKey }

/// The app's live entitlement, derived from whatever token is stored. `.free` unless a valid, unexpired Pro
/// token is present. Persisted token lives in `SovereignStore.secret("license")`.
public struct Entitlement: Equatable, Sendable {
    public enum Tier: String, Sendable { case free, pro }
    public let tier: Tier
    public let payload: LicensePayload?
    public var isPro: Bool { tier == .pro }

    public static let free = Entitlement(tier: .free, payload: nil)

    public static func from(token: String?, now: Date = Date()) -> Entitlement {
        guard let token, let p = License.verify(token), p.isValid(now: now) else { return .free }
        return Entitlement(tier: .pro, payload: p)
    }

    /// Load the stored license token and resolve the current entitlement.
    public static func current(now: Date = Date()) -> Entitlement {
        from(token: SovereignStore.secret("license"), now: now)
    }
    /// Store a token after verifying it's genuine + unexpired; returns the resolved entitlement (or nil if bad).
    @discardableResult
    public static func store(_ token: String, now: Date = Date()) -> Entitlement? {
        let e = from(token: token, now: now)
        guard e.isPro else { return nil }
        SovereignStore.saveSecret("license", token)
        return e
    }
    public static func clear() { SovereignStore.deleteSecret("license") }
}

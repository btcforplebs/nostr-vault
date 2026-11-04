import CryptoKit
import Foundation
import Security

/// Two-scan device pairing: the QR codes, the hello and ack, and the checks.
/// Pure: no I/O, no keys. The contract is docs/MESH_PAIRING_CONTRACT.md, and
/// Kotlin (fips/MeshPairing.kt) and the web (src/net/mesh-pairing.js) agree
/// with it through the fixtures in MediaLogicTests/Fixtures/MeshPairing.
enum MeshPairing {
    static let helloKind = 21195
    /// Seconds A's code may open the camera after it is shown.
    static let codeLifetime = 180
    /// Seconds A has to scan B's code (or Accept) after the hello.
    static let scanWindow = 180
    /// Seconds B waits for the ack after scanning A.
    static let ackWindow = 360
    /// A hello's own time must be this close to now.
    static let helloSkew = 180
    /// A device name, in Unicode code points.
    static let nameMax = 40
    static let wireRoles: [MeshDeviceRole] = [.phone, .mac, .homeVault, .browser]

    enum Refusal: String, Equatable {
        case notPairing, unsupportedVersion, malformed, badAddress, unknownRole, missingOwner, badCode, nameTooLong, ownAddress
    }

    enum Code: Equatable {
        /// A's code: its one-time secret.
        case secret(String)
        /// B's code: A's secret, echoed.
        case echo(String)

        var value: String {
            switch self {
            case .secret(let s), .echo(let s): return s
            }
        }
    }

    struct Payload: Equatable {
        var mesh: String
        var meshHex: String
        var name: String
        var role: MeshDeviceRole
        var owner: String
        var ownerHex: String
        var code: Code
    }

    // MARK: The QR

    static func build(mesh: String, name: String, role: MeshDeviceRole, owner: String, code: Code) -> String {
        var query = ["m=\(mesh)"]
        let n = cleanName(name)
        if !n.isEmpty { query.append("n=\(percentEncode(n))") }
        query.append("r=\(role.rawValue)")
        query.append("o=\(owner)")
        switch code {
        case .secret(let s): query.append("s=\(s)")
        case .echo(let e): query.append("e=\(e)")
        }
        return "nvpair:v1?" + query.joined(separator: "&")
    }

    /// The pairing code in `uri`, or why it can't be used. `ownMesh` is this
    /// device's own mesh npub.
    static func parse(_ uri: String, ownMesh: String?) -> Result<Payload, RefusalError> {
        let u = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.count >= 7, u.prefix(7).lowercased() == "nvpair:" else { return .failure(.init(.notPairing)) }
        let rest = u.dropFirst(7)
        let version: Substring
        let query: Substring
        if let q = rest.firstIndex(of: "?") {
            version = rest[..<q]
            query = rest[rest.index(after: q)...]
        } else {
            version = rest
            query = ""
        }
        guard version == "v1" else { return .failure(.init(.unsupportedVersion)) }
        var fields: [String: String] = [:]
        if !query.isEmpty {
            for part in query.split(separator: "&", omittingEmptySubsequences: false) {
                guard let eq = part.firstIndex(of: "=") else { return .failure(.init(.malformed)) }
                let key = String(part[..<eq])
                guard fields[key] == nil, let value = percentDecode(String(part[part.index(after: eq)...])) else {
                    return .failure(.init(.malformed))
                }
                fields[key] = value
            }
        }
        guard let meshHex = npubHex(fields["m"]) else { return .failure(.init(.badAddress)) }
        guard let r = fields["r"], let role = MeshDeviceRole(rawValue: r), wireRoles.contains(role) else {
            return .failure(.init(.unknownRole))
        }
        guard let ownerHex = npubHex(fields["o"]) else { return .failure(.init(.missingOwner)) }
        let s = fields["s"], e = fields["e"]
        guard (s == nil) != (e == nil), let raw = s ?? e, secretBytes(raw) != nil else { return .failure(.init(.badCode)) }
        let name = (fields["n"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.unicodeScalars.count <= nameMax else { return .failure(.init(.nameTooLong)) }
        if let ownMesh, npubHex(ownMesh) == meshHex { return .failure(.init(.ownAddress)) }
        return .success(Payload(
            mesh: npub(hex: meshHex), meshHex: meshHex, name: name, role: role,
            owner: npub(hex: ownerHex), ownerHex: ownerHex, code: s != nil ? .secret(raw) : .echo(raw)
        ))
    }

    struct RefusalError: Error, Equatable {
        let refusal: Refusal
        init(_ refusal: Refusal) { self.refusal = refusal }
    }

    // MARK: Owner and role

    enum OwnerCheck: Equatable {
        case ok
        /// Another account on this device: switch to it first.
        case switchTo(String)
        case otherOwner
    }

    /// `owner` against every account on this device, not only the active one.
    static func ownerCheck(owner: String, active: String?, accounts: [String]) -> OwnerCheck {
        guard let hex = npubHex(owner) else { return .otherOwner }
        if let active, npubHex(active) == hex { return .ok }
        if let match = accounts.first(where: { npubHex($0) == hex }) { return .switchTo(match) }
        return .otherOwner
    }

    enum RoleCheck: Equatable {
        case add
        case alreadyLinked
        /// Known under another role: never moved silently (Tron 1).
        case refuseOtherRole(MeshDeviceRole)
    }

    static func roleCheck(npub: String, role: MeshDeviceRole, existing: [MeshDevice]) -> RoleCheck {
        let hex = npubHex(npub)
        guard let known = existing.first(where: { npubHex($0.npub) == hex }) else { return .add }
        return known.role == role ? .alreadyLinked : .refuseOtherRole(known.role)
    }

    // MARK: Words people read

    /// The role confirm the person taps before anything is stored (Tron 1).
    /// `setup` is the first-run "bring it over" wording, with no role words.
    static func roleConfirmText(role: MeshDeviceRole, name: String, setup: Bool = false) -> String {
        let n = displayName(name)
        if setup { return "Add \(n) as another of your devices: your vault copies between them." }
        switch role {
        case .mac: return "Add \(n) as your Mac: your vault syncs to it and it keeps a full copy."
        case .homeVault: return "Add \(n) as your home vault: your new posts and media are sent to it."
        case .browser: return "Add \(n) as your browser vault: it gets your new notes while it's open."
        case .phone: return "Add \(n) as another of your phones."
        }
    }

    static let unreadable = "That code didn't read correctly. Try scanning again."

    static func text(_ refusal: Refusal) -> String {
        switch refusal {
        case .notPairing: return "That isn't a Nostr Vault pairing code."
        case .unsupportedVersion: return "That code is from a newer Nostr Vault. Update this app and try again."
        case .malformed, .badAddress, .missingOwner, .badCode, .nameTooLong: return unreadable
        case .unknownRole: return "This version can't link that kind of device. Update this app and try again."
        case .ownAddress: return "That's this device's own code."
        }
    }

    static let otherOwnerText = "That device belongs to another account. Only your own devices can be linked."
    static let alreadyLinkedText = "Already linked."
    static let expiredText = "This code has expired. Show a new one."
    static let abortText = "Another device tried to use this code. Start again, and only show your code to your own device."

    static func switchToText(accountName: String) -> String {
        let t = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = t.isEmpty ? "that account" : t
        return "This is \(n)'s device. Switch to \(n) first."
    }

    static func otherRoleText(_ role: MeshDeviceRole) -> String {
        "This device is already added as your \(roleWord(role)). Remove it in Mesh settings first."
    }

    static func roleWord(_ role: MeshDeviceRole) -> String {
        switch role {
        case .phone: return "phone"
        case .mac: return "Mac"
        case .homeVault: return "home vault"
        case .browser: return "browser vault"
        }
    }

    /// "npub1abc…wxyz", as AccountSwitcherIdentity.shortNpub and Android.
    static func shortAddress(_ npub: String) -> String {
        npub.count <= 12 ? npub : String(npub.prefix(8)) + "…" + String(npub.suffix(4))
    }

    static func displayName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "this device" : t
    }

    // MARK: Hello and ack (the decrypted content of a kind-21195 event)

    struct Hello: Equatable {
        var secret: String
        var name: String
        var role: MeshDeviceRole
        var owner: String
        var time: Int
    }

    struct Ack: Equatable {
        var digest: String
        /// A linked by Accept with the check words, so B needs its own tap.
        var words: Bool
    }

    static func helloJSON(secret: String, name: String, role: MeshDeviceRole, owner: String, time: Int) -> String {
        var parts = ["\"v\":1", "\"s\":\(jsonString(secret))"]
        let n = cleanName(name)
        if !n.isEmpty { parts.append("\"n\":\(jsonString(n))") }
        parts += ["\"r\":\(jsonString(role.rawValue))", "\"o\":\(jsonString(owner))", "\"t\":\(time)"]
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func ackJSON(digest: String, words: Bool) -> String {
        "{\"v\":1,\"ack\":true,\"d\":\(jsonString(digest))" + (words ? ",\"w\":true}" : "}")
    }

    static func parseHello(_ text: String) -> Hello? {
        guard let d = jsonObject(text), intValue(d["v"]) == 1, d["ack"] == nil,
              let s = d["s"] as? String, secretBytes(s) != nil,
              let r = d["r"] as? String, let role = MeshDeviceRole(rawValue: r), wireRoles.contains(role),
              let o = d["o"] as? String, let ownerHex = npubHex(o),
              let t = intValue(d["t"]) else { return nil }
        let rawName = d["n"] ?? ""
        guard let n = rawName as? String else { return nil }
        let name = n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.unicodeScalars.count <= nameMax else { return nil }
        return Hello(secret: s, name: name, role: role, owner: npub(hex: ownerHex), time: t)
    }

    static func parseAck(_ text: String) -> Ack? {
        guard let d = jsonObject(text), intValue(d["v"]) == 1, isTrue(d["ack"]),
              let digest = d["d"] as? String, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        var words = false
        if let w = d["w"] {
            guard isBool(w) else { return nil }
            words = isTrue(w)
        }
        return Ack(digest: digest, words: words)
    }

    // MARK: Digests

    /// hex SHA-256(s_A ‖ m_A ‖ m_B), the ack's proof (Tron 2).
    static func ackDigest(secret: String, aHex: String, bHex: String) -> String? {
        guard let s = secretBytes(secret), let a = Bech32.hexToData(aHex), let b = Bech32.hexToData(bHex),
              a.count == 32, b.count == 32 else { return nil }
        return SHA256.hash(data: s + a + b).map { String(format: "%02x", $0) }.joined()
    }

    /// The 4 check words both screens show on the Accept path: the first 44
    /// bits of SHA-256(m_A ‖ m_B ‖ s_A), 11 bits a word, BIP-39 English.
    static func checkWords(aHex: String, bHex: String, secret: String) -> [String]? {
        guard let s = secretBytes(secret), let a = Bech32.hexToData(aHex), let b = Bech32.hexToData(bHex),
              a.count == 32, b.count == 32 else { return nil }
        let h = Array(SHA256.hash(data: a + b + s))
        var n: UInt64 = 0
        for byte in h.prefix(6) { n = n << 8 | UInt64(byte) }
        n >>= 4
        let list = MeshPairingWords.list
        return (0..<4).map { i in list[Int((n >> UInt64(11 * (3 - i))) & 2047)] }
    }

    // MARK: Helpers

    /// A fresh one-time secret: 16 random bytes, base64url.
    static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return base64url(Data(bytes))
    }

    /// The 32-byte key of an npub as hex, or nil. Upper or lower case, never mixed.
    static func npubHex(_ s: String?) -> String? {
        guard let s, s.count == 63, s.lowercased() == s || s.uppercased() == s else { return nil }
        let lower = s.lowercased()
        guard lower.hasPrefix("npub1"), Bech32.hasValidChecksum(lower), let r = Bech32.decode(lower),
              r.hrp == "npub", r.data.count == 32 else { return nil }
        return r.hexString
    }

    static func npub(hex: String) -> String {
        guard let d = Bech32.hexToData(hex), let n = Bech32.encode(hrp: "npub", data: d) else { return hex }
        return n
    }

    static func secretBytes(_ s: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        guard s.count == 22, s.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let standard = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        guard let d = Data(base64Encoded: standard), d.count == 16, base64url(d) == s else { return nil }
        return d
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func cleanName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: t.unicodeScalars.prefix(nameMax))
        return String(scalars)
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".unicodeScalars)

    static func percentEncode(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if unreserved.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            }
        }
        return out
    }

    static func percentDecode(_ s: String) -> String? {
        var bytes: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            if c == UInt8(ascii: "%") {
                guard it.count >= 2, let hi = hexNibble(it.popFirst()!), let lo = hexNibble(it.popFirst()!) else { return nil }
                bytes.append(hi << 4 | lo)
            } else {
                bytes.append(c)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast())
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func isTrue(_ v: Any?) -> Bool {
        guard let v, isBool(v) else { return false }
        return (v as? Bool) == true
    }

    /// A JSON integer (not a bool, not a fraction).
    private static func intValue(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 1e15 else { return nil }
        return n.intValue
    }
}

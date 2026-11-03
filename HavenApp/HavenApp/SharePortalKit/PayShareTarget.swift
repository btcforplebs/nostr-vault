import Foundation

// MARK: - What a "Pay or zap" share points at
//
// The classifier only says "there is something payable in here". This finds
// it: the first invoice, else the first LNURL, else the whole text when it is
// a lightning address. Pure, mirrored by PayShareTarget.kt and tested with the
// same fixture (pay-target-cases.json). The share sheet never sets an amount;
// whatever amount the app shows comes from the invoice itself or from what the
// person types on the review card.

struct PayShareTarget: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case invoice, lnurl, address
    }

    /// Lowercased, with any `lightning:` prefix removed.
    let token: String
    let kind: Kind
    /// The one npub the share also names, if exactly one. A zap goes to it
    /// only when its profile's own lightning address is `token`.
    let recipientNpub: String?

    static func find(url: String?, text: String?, selection: String?) -> PayShareTarget? {
        let haystack = [url, text, selection].compactMap { $0 }.joined(separator: "\n")
        let npub = onlyNpub(in: haystack)
        if let m = first(bolt11, in: haystack) { return .init(token: strip(m), kind: .invoice, recipientNpub: npub) }
        if let m = first(lnurl, in: haystack) { return .init(token: strip(m), kind: .lnurl, recipientNpub: npub) }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed.count <= 320, first(lightningAddress, in: trimmed) != nil {
            return .init(token: strip(trimmed), kind: .address, recipientNpub: npub)
        }
        return nil
    }

    /// A zap is offered only when the shared address is the recipient's own
    /// published one, so it can never route money somewhere their profile
    /// does not already say.
    static func canZap(_ target: PayShareTarget, profileLightningAddress: String?) -> Bool {
        guard target.kind == .address, target.recipientNpub != nil,
              let lud16 = profileLightningAddress?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !lud16.isEmpty else { return false }
        return lud16 == target.token
    }

    // The classifier's own patterns (contract §3), so a share that offered
    // Pay always finds its target here.
    private static let bech32 = "[qpzry9x8gf2tvdw0s3jn54khce6mua7l]"
    private static let bolt11 = #"(?i)\b(?:lightning:)?ln(?:bc|tb|tbs|bcrt)[0-9a-z]{20,}\b"#
    private static let lnurl = #"(?i)\b(?:lightning:)?lnurl1[0-9a-z]{20,}\b"#
    private static let lightningAddress = #"(?i)^(?:lightning:)?[a-z0-9._-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}$"#
    private static let npub = "(?i)\\bnpub1\(bech32){58}\\b"

    private static func first(_ pattern: String, in s: String) -> String? {
        s.range(of: pattern, options: .regularExpression).map { String(s[$0]) }
    }

    private static func strip(_ s: String) -> String {
        var lower = s.lowercased()
        if lower.hasPrefix("lightning:") { lower.removeFirst("lightning:".count) }
        return lower
    }

    private static func onlyNpub(in s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: npub) else { return nil }
        let ns = s as NSString
        let found = Set(regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() })
        return found.count == 1 ? found.first : nil
    }
}

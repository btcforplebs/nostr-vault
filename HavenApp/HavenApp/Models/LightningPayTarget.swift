import Foundation

/// What someone pasted (or scanned) into the wallet's Send box.
///
/// One box takes every shape people actually hand each other — a bolt11
/// invoice, a Lightning address, a bech32 LNURL, an LUD-17 `lnurlp://` /
/// `lnurlw://` link, and any of those behind a `lightning:` prefix or inside a
/// BIP21 `bitcoin:` link — so the user never has to know which one they have.
enum LightningPayTarget: Equatable {
    /// A bolt11 invoice, lowercased.
    case invoice(String)
    /// A Lightning address (LUD-16), `name@domain`, lowercased.
    case address(String)
    /// A bech32 LNURL (LUD-01), lowercased, still encoded.
    case lnurl(String)
    /// An LUD-17 link already turned into the https URL it stands for.
    case lnurlURL(URL)

    static func parse(_ raw: String) -> LightningPayTarget? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // BIP21: `bitcoin:addr?amount=…&lightning=lnbc…` — the lightning
        // parameter is the part this wallet can pay.
        if text.lowercased().hasPrefix("bitcoin:"),
           let query = text.split(separator: "?", maxSplits: 1).dropFirst().first {
            let pairs = query.split(separator: "&")
            guard let lightning = pairs.first(where: { $0.lowercased().hasPrefix("lightning=") }) else { return nil }
            text = String(lightning.dropFirst("lightning=".count)).removingPercentEncoding ?? String(lightning.dropFirst("lightning=".count))
        }

        if text.lowercased().hasPrefix("lightning:") {
            text = String(text.dropFirst("lightning:".count))
            // Some wallets write `lightning://`.
            while text.hasPrefix("/") { text.removeFirst() }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        for scheme in ["lnurlp://", "lnurlw://"] where lower.hasPrefix(scheme) {
            let rest = text.dropFirst(scheme.count)
            // LUD-17: onion hosts stay on http, everything else is https.
            let host = rest.split(separator: "/", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            let httpScheme = host.hasSuffix(".onion") ? "http://" : "https://"
            guard let url = URL(string: httpScheme + rest), url.host != nil else { return nil }
            return .lnurlURL(url)
        }

        if lower.hasPrefix("lnurl1") {
            return .lnurl(lower)
        }

        // Before the invoice test: `lntbob@getalby.com` is an address.
        if isLightningAddress(lower) {
            return .address(lower)
        }

        // lnbc (mainnet), lntb (testnet), lntbs (signet), lnbcrt (regtest).
        if (lower.hasPrefix("lnbc") || lower.hasPrefix("lntb")) && !lower.contains("@") {
            return .invoice(lower)
        }
        return nil
    }

    /// `name@domain.tld` with nothing the well-known URL could not carry.
    static func isLightningAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let name = parts[0], domain = parts[1]
        guard !name.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        let nameChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.+")
        let domainChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.:")
        return name.unicodeScalars.allSatisfy(nameChars.contains)
            && domain.unicodeScalars.allSatisfy(domainChars.contains)
    }
}

/// The range an LNURL service will accept, and whether an amount fits it.
/// LNURL speaks millisatoshis; people type sats.
struct LNURLAmountRange: Equatable {
    let minMsat: Int
    let maxMsat: Int

    /// Smallest whole sat the service accepts (rounded up).
    var minSats: Int { (minMsat + 999) / 1000 }
    /// Largest whole sat the service accepts (rounded down).
    var maxSats: Int { maxMsat / 1000 }
    /// Services that take exactly one amount (a fixed-price LNURL).
    var isFixed: Bool { minSats == maxSats }

    enum Check: Equatable {
        case ok(msat: Int)
        case tooSmall(minSats: Int)
        case tooLarge(maxSats: Int)
        case invalid
    }

    func check(sats: Int?) -> Check {
        guard let sats, sats > 0 else { return .invalid }
        // Compared in sats first: `sats * 1000` traps for a long enough
        // number typed into the field, and this runs on every keystroke.
        if sats > maxSats { return .tooLarge(maxSats: maxSats) }
        let msat = sats * 1000
        if msat < minMsat { return .tooSmall(minSats: minSats) }
        return .ok(msat: msat)
    }
}

/// One payment from the wallet's history (NIP-47 `list_transactions`).
struct WalletTransaction: Identifiable, Equatable {
    enum Direction: Equatable { case incoming, outgoing }
    enum State: Equatable { case settled, pending, failed, expired }

    let id: String
    let direction: Direction
    let state: State
    let amountSats: Int
    let feeSats: Int
    /// The invoice's own description, or nil when it is empty or is a zap
    /// request (which is JSON, and goes to `zap` instead).
    let description: String?
    let createdAt: Date
    let settledAt: Date?
    let paymentHash: String?
    let invoice: String?
    /// Set when the wallet returned the zap request as the description.
    let zap: ZapDetail?

    /// Builds one from the decrypted NIP-47 transaction object. Wallets are
    /// loose about number types (int, double, numeric string), so every
    /// number is read through `number(_:)`. Returns nil only when the entry is
    /// unusable — no direction or no time.
    init?(nip47 dict: [String: Any]) {
        guard let type = dict["type"] as? String else { return nil }
        switch type.lowercased() {
        case "incoming": direction = .incoming
        case "outgoing": direction = .outgoing
        default: return nil
        }
        guard let created = Self.number(dict["created_at"]) else { return nil }
        createdAt = Date(timeIntervalSince1970: TimeInterval(created))
        settledAt = Self.number(dict["settled_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        amountSats = (Self.number(dict["amount"]) ?? 0) / 1000
        feeSats = (Self.number(dict["fees_paid"]) ?? 0) / 1000

        let desc = (dict["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        zap = desc.flatMap { ZapDetail.fromZapRequest(json: $0) }
        description = (desc?.isEmpty ?? true) || zap != nil ? nil : desc

        // `state` is newer in NIP-47; older wallets only send `settled_at`.
        switch (dict["state"] as? String)?.lowercased() {
        case "settled": state = .settled
        case "pending": state = .pending
        case "failed": state = .failed
        case "expired": state = .expired
        default: state = settledAt != nil ? .settled : .pending
        }

        let hash = (dict["payment_hash"] as? String)?.lowercased()
        let invoice = (dict["invoice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        paymentHash = hash ?? invoice.flatMap { Bolt11.paymentHash($0) }
        self.invoice = invoice
        id = hash ?? invoice ?? "\(type)-\(created)-\(amountSats)"
    }

    init(id: String, direction: Direction, state: State, amountSats: Int, feeSats: Int,
         description: String?, createdAt: Date, settledAt: Date?,
         paymentHash: String? = nil, invoice: String? = nil, zap: ZapDetail? = nil) {
        self.paymentHash = paymentHash
        self.invoice = invoice
        self.zap = zap
        self.id = id
        self.direction = direction
        self.state = state
        self.amountSats = amountSats
        self.feeSats = feeSats
        self.description = description
        self.createdAt = createdAt
        self.settledAt = settledAt
    }

    private static func number(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let d as Double: return Int(exactly: d.rounded(.towardZero))
        case let s as String: return Int(s) ?? Double(s).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        default: return nil
        }
    }

    /// Wallets return history newest first in theory, not always in
    /// practice; pages are merged and re-sorted, and a payment that shows up
    /// on two pages (the list moved between requests) appears once.
    static func merge(_ existing: [WalletTransaction], _ page: [WalletTransaction]) -> [WalletTransaction] {
        var seen = Set<String>()
        return (existing + page)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

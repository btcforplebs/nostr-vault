import SwiftUI

/// Pay or zap (lane D). The share sheet only queues what was shared; the
/// review card reads the amount from the invoice (or takes it from the person
/// for a lightning address / LNURL), asks once more, re-checks the invoice
/// has not lapsed, and pays through the connected wallet (NWC).
///
/// Money rules (Tron review, mandatory):
/// - Nothing is paid without the confirm on the review card.
/// - An invoice that names no amount is refused, never paid "any amount".
/// - LUD-06: an LNURL invoice for a different amount than asked is refused.
/// - Once a wallet call for an LNURL / zap has started, this share can never
///   pay again (a retry would fetch a new invoice and pay twice), even if the
///   app is killed and the card comes back.
struct PayShareHandler: SharePortalHandler {
    let action = NVShareAction.pay

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(PayReviewView(intent: intent, close: close))
    }
}

extension PayShareHandler {
    enum PayError: LocalizedError {
        case expired, noAmount, wrongAmount(String), accountChanged, alreadyTried, signing
        var errorDescription: String? {
            switch self {
            case .expired: return "This invoice has expired, so nothing was sent."
            case .noAmount: return "This invoice names no amount. Nostr Vault won't pay it from a share."
            case .wrongAmount(let who): return "\(who) returned an invoice for a different amount, so nothing was sent."
            case .accountChanged: return "The account changed, so nothing was sent."
            case .alreadyTried: return "A payment was already tried from this share. Check your wallet's history."
            case .signing: return "The zap request wasn't signed, so nothing was sent."
            }
        }
    }

    /// The account whose wallet pays (and who signs a zap).
    static func account(for intent: NVShareIntent) -> String {
        let config = ConfigService.shared.config
        return intent.account ?? PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub)
    }

    static func target(of intent: NVShareIntent) -> PayShareTarget? {
        PayShareTarget.find(url: intent.source.url, text: intent.source.text, selection: intent.source.selection)
    }

    /// Pays a shared bolt11. Expiry and amount are checked again here, at the
    /// moment of paying, not only when the card was drawn. Retrying the same
    /// invoice is safe: a wallet cannot settle one payment hash twice.
    static func payInvoice(_ invoice: String, intent: NVShareIntent) async throws {
        guard let details = Bolt11.details(invoice) else { throw LNURLService.LNURLError.invalidInvoice }
        guard case .sats = details.amount else { throw PayError.noAmount }
        guard !details.isExpired() else { throw PayError.expired }
        try requireActive(intent)
        PayShareAttempts.mark(intent.id, .tried)
        _ = try await NWCService.payInvoice(bolt11: invoice)
        PayShareAttempts.mark(intent.id, .paid)
    }

    /// LNURL-pay (an address or LNURL), as a plain payment or, when `zapTo`
    /// is set, as a public zap to that pubkey.
    static func payLNURL(_ pay: LNURLService.LNURLPayResponse, token: String, msat: Int, comment: String,
                         zapTo recipientHex: String?, host: String, intent: NVShareIntent) async throws {
        guard PayShareAttempts.state(intent.id) == nil else { throw PayError.alreadyTried }
        try requireActive(intent)
        var zapRequest: NostrEvent?
        if let recipientHex {
            zapRequest = try await signZapRequest(to: recipientHex, lnurl: token, msat: msat, comment: comment, intent: intent)
        }
        let invoice = try await LNURLService.fetchInvoice(callback: pay.callback, amountMsat: msat, zapRequest: zapRequest,
                                                          comment: zapRequest == nil && !comment.isEmpty ? comment : nil)
        // LUD-06: exact msat, or a service could add up to 999 on top.
        guard Bolt11.msat(invoice) == msat else { throw PayError.wrongAmount(host) }
        if let details = Bolt11.details(invoice), details.isExpired() { throw PayError.expired }
        try requireActive(intent)
        // From here on a retry could pay twice: the card never offers one.
        PayShareAttempts.mark(intent.id, .tried)
        _ = try await NWCService.payInvoice(bolt11: invoice)
        PayShareAttempts.mark(intent.id, .paid)
    }

    private static func requireActive(_ intent: NVShareIntent) throws {
        let config = ConfigService.shared.config
        guard PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub) == account(for: intent)
        else { throw PayError.accountChanged }
    }

    /// Kind 9734, signed by the share's account only (the same lock a post
    /// uses), never published by us: the LNURL service publishes the receipt.
    private static func signZapRequest(to recipientHex: String, lnurl: String, msat: Int, comment: String,
                                       intent: NVShareIntent) async throws -> NostrEvent {
        let npub = account(for: intent)
        guard let hex = Bech32.decode(npub)?.hexString else { throw PayError.signing }
        let tags: [[String]] = [
            ["p", recipientHex],
            ["relays"] + ZapService.receiptRelays(me: hex, recipient: recipientHex),
            ["amount", String(msat)],
            ["lnurl", lnurl],
        ]
        guard let event = await NostrService.shared.signEventAsync(kind: 9734, content: ZapComment.content(comment), tags: tags)
        else { throw PayError.signing }
        let config = ConfigService.shared.config
        guard PostingAccount.signedAsLocked(lockedNpub: npub, lockedHex: hex, activeNow: config.activeAccountNpub,
                                            owner: config.ownerNpub, eventPubkey: event.pubkey)
        else { throw PayError.accountChanged }
        return event
    }
}

/// What happened to each pay share, by intent id, kept outside the queue so a
/// card that comes back after the app was killed still knows. Small and
/// bounded: the newest 200 ids.
enum PayShareAttempts {
    enum State: String { case tried, paid }
    private static let key = "nv.sharePortal.payAttempts"
    private static let cap = 200

    static func state(_ id: String, defaults: UserDefaults = .standard) -> State? {
        (defaults.array(forKey: key) as? [[String]])?.last { $0.first == id }.flatMap { $0.count == 2 ? State(rawValue: $0[1]) : nil }
    }

    static func mark(_ id: String, _ state: State, defaults: UserDefaults = .standard) {
        var list = (defaults.array(forKey: key) as? [[String]] ?? []).filter { $0.first != id }
        list.append([id, state.rawValue])
        defaults.set(Array(list.suffix(cap)), forKey: key)
    }
}

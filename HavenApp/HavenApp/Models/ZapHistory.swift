import Foundation

/// Who a zap in the wallet history came from (or went to) and which post it
/// was for.
///
/// A wallet's history only knows amounts and invoices. The people and the
/// post live in the NIP-57 zap request (kind 9734): it is the invoice's
/// description, so some wallets hand it back as the transaction description,
/// and it is embedded in the public zap receipt (kind 9735) that also
/// carries the paid bolt11. Either source gives the same `ZapDetail`.
struct ZapDetail: Equatable {
    /// Whoever sent the zap — the zap request's author. For an anonymous
    /// zap this is a throwaway key, so `isAnonymous` must be checked first.
    let senderPubkey: String
    /// Whoever was zapped (the request's `p` tag).
    let recipientPubkey: String?
    /// The post that was zapped (the request's `e` tag), if it was a post
    /// rather than a profile.
    let postId: String?
    /// What the sender wrote with the zap.
    let comment: String?
    let isAnonymous: Bool
    /// The zap request exactly as it arrived, so its signature can be checked
    /// before any of the above is believed: the fields are whatever its
    /// author wrote, and only a valid signature makes the author who it says.
    var requestJSON: String? = nil

    /// The person on the other side of the payment from `me`.
    func counterparty(me: String, direction: WalletTransaction.Direction) -> String? {
        switch direction {
        case .incoming: return isAnonymous ? nil : senderPubkey
        case .outgoing: return recipientPubkey
        }
    }

    /// Reads a zap request (kind 9734) given as JSON text. Returns nil for
    /// anything else — which is how a plain invoice description is told apart.
    static func fromZapRequest(json: String) -> ZapDetail? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var detail = fromZapRequest(obj) else { return nil }
        detail.requestJSON = trimmed
        return detail
    }

    static func fromZapRequest(_ obj: [String: Any]) -> ZapDetail? {
        guard (obj["kind"] as? Int) == 9734,
              let pubkey = obj["pubkey"] as? String, !pubkey.isEmpty else { return nil }
        let tags = obj["tags"] as? [[String]] ?? []
        let comment = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZapDetail(
            senderPubkey: pubkey,
            recipientPubkey: firstTag("p", in: tags),
            postId: firstTag("e", in: tags),
            comment: (comment?.isEmpty ?? true) ? nil : comment,
            isAnonymous: tags.contains { $0.first == "anon" }
        )
    }

    private static func firstTag(_ name: String, in tags: [[String]]) -> String? {
        tags.first { $0.count >= 2 && $0[0] == name && !$0[1].isEmpty }?[1]
    }
}

/// A zap receipt (kind 9735) reduced to what history matching needs.
struct ZapReceipt: Equatable {
    let paymentHash: String?
    let bolt11: String
    let detail: ZapDetail

    /// From a receipt's tags: `bolt11` is the paid invoice, `description`
    /// the zap request. A receipt missing either is unusable.
    init?(tags: [[String]]) {
        func tag(_ name: String) -> String? {
            tags.first { $0.count >= 2 && $0[0] == name }?[1]
        }
        guard let bolt11 = tag("bolt11")?.lowercased(),
              let description = tag("description"),
              let detail = ZapDetail.fromZapRequest(json: description) else { return nil }
        self.bolt11 = bolt11
        self.paymentHash = Bolt11.paymentHash(bolt11)
        self.detail = detail
    }

    /// Pairs each transaction with its receipt: by payment hash when both
    /// sides have one, otherwise by the invoice text itself.
    ///
    /// Two receipts that tell different stories about the same payment mean
    /// at least one is forged, and there is no telling which: that payment
    /// gets neither.
    static func match(_ transactions: [WalletTransaction], _ receipts: [ZapReceipt]) -> [String: ZapDetail] {
        var byHash: [String: ZapDetail] = [:]
        var byInvoice: [String: ZapDetail] = [:]
        var conflictedHashes = Set<String>()
        var conflictedInvoices = Set<String>()
        for r in receipts {
            if let h = r.paymentHash {
                if let seen = byHash[h], seen != r.detail { conflictedHashes.insert(h) }
                byHash[h] = r.detail
            }
            if let seen = byInvoice[r.bolt11], seen != r.detail { conflictedInvoices.insert(r.bolt11) }
            byInvoice[r.bolt11] = r.detail
        }
        var out: [String: ZapDetail] = [:]
        for tx in transactions {
            if let h = tx.paymentHash, byHash[h] != nil {
                if !conflictedHashes.contains(h) { out[tx.id] = byHash[h] }
            } else if let inv = tx.invoice?.lowercased(), let d = byInvoice[inv], !conflictedInvoices.contains(inv) {
                out[tx.id] = d
            }
        }
        return out
    }
}

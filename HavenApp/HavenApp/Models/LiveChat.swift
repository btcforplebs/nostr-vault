import Foundation

/// Pure parsing for a live stream's chat (NIP-53 kind 1311) and the zap
/// receipts (NIP-57 kind 9735) that are addressed to the same stream.
///
/// Kept free of SwiftUI and Combine so `MediaLogicTests` can compile it: the
/// awkward parts here — a zap receipt is signed by the *provider*, not the
/// person who paid, and half of them omit the amount tag — are exactly the
/// parts worth testing without a running app.

/// One row in the chat column.
struct LiveChatMessage: Identifiable, Equatable {
    enum Payload: Equatable {
        case chat
        /// Amount in sats. Zero means the receipt carried no amount we could read.
        case zap(sats: Int)
    }

    let id: String
    /// The person to attribute the row to. For a zap that is the payer taken
    /// from the embedded request, never the receipt's own pubkey.
    let authorPubkey: String
    let createdAt: Int64
    let text: String
    let payload: Payload

    var isZap: Bool { if case .zap = payload { return true }; return false }
    var zapSats: Int? { if case .zap(let sats) = payload { return sats }; return nil }
}

enum LiveChat {
    /// The relay hint every chat message and stream zap carries. Kept because
    /// it is the address other clients look for, *not* because chat is there.
    static let streamRelay = "wss://relay.zap.stream"

    /// Where live chat actually is, measured 2026-09-07 against the 19 live
    /// playable streams on the network: zap.stream returned 0 chat events for
    /// all 19, while nos.lol returned 200 (140 chat, 60 zaps) across 4 of them,
    /// relay.damus.io 200 across 3, and relay.primal.net 200 across 2.
    /// Following the documented relay alone shows an empty room for a stream
    /// that is busy.
    static let defaultChatRelays = [
        "wss://nos.lol",
        "wss://relay.damus.io",
        "wss://relay.primal.net"
    ]

    /// Who to ask for a stream's chat, best source first.
    ///
    /// The stream can say where its chat is (`relays` tag) and that answer
    /// beats any list of ours — but only 6 of those 19 streams published one,
    /// so it cannot be the only rung.
    static func chatRelays(streamRelays: [String], userRelays: [String], limit: Int = 5) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        for candidate in streamRelays + defaultChatRelays + userRelays + [streamRelay] {
            guard let normalized = normalizedRelay(candidate) else { continue }
            // Hosts advertise both `wss://nos.lol` and `wss://nos.lol/`; without
            // folding those together we open two sockets to the same relay and
            // print every message twice.
            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(normalized)
            if ordered.count == limit { break }
        }
        return ordered
    }

    /// A relay URL we can open, with the trailing slash folded away, or nil.
    static func normalizedRelay(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              url.host?.isEmpty == false
        else { return nil }
        return trimmed
    }

    /// The `a` tag every chat message and stream zap is addressed to.
    static func address(hostPubkey: String, identifier: String) -> String {
        "30311:\(hostPubkey):\(identifier)"
    }

    /// Who a zap for this stream should pay.
    ///
    /// NIP-53 lets the event be published by a service on the host's behalf
    /// (zap.stream does exactly this), with the real host carried as a `p` tag
    /// tagged `Host`. Paying the author in that case pays the service.
    static func hostPubkey(authorPubkey: String, tags: [[String]]) -> String {
        let host = tags.first { tag in
            tag.count >= 4 && tag[0] == "p" && tag[3].lowercased() == "host" && !tag[1].isEmpty
        }
        return host?[1] ?? authorPubkey
    }

    /// Whether a stream belongs in a Following feed.
    ///
    /// A service such as shosho.live publishes every stream under its own key,
    /// with the streamer only in the `Host` p tag, so checking the author alone
    /// never matches anyone the owner follows. Other p tags (guests, speakers)
    /// do not count: a followed guest does not make the stream theirs.
    static func isFollowed(authorPubkey: String, tags: [[String]], follows: Set<String>) -> Bool {
        follows.contains(authorPubkey) || follows.contains(hostPubkey(authorPubkey: authorPubkey, tags: tags))
    }

    /// Builds a row from a relay event, or nil if it is not one we render.
    static func message(id: String, pubkey: String, kind: Int, createdAt: Int64,
                        content: String, tags: [[String]]) -> LiveChatMessage? {
        guard !id.isEmpty else { return nil }

        if kind == 1311 {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveChatMessage(id: id, authorPubkey: pubkey, createdAt: createdAt,
                                   text: text, payload: .chat)
        }

        guard kind == 9735 else { return nil }

        let request = zapRequest(from: tags)
        // The receipt is signed by the LNURL provider. The payer is in the
        // embedded request; NIP-57's optional `P` tag is the only other place
        // it appears, and plenty of providers set neither.
        let payer = request?.pubkey
            ?? tags.first { $0.count >= 2 && $0[0] == "P" && !$0[1].isEmpty }?[1]
            ?? pubkey
        let sats = zapAmountSats(receiptTags: tags, requestTags: request?.tags ?? [])
        let comment = (request?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveChatMessage(id: id, authorPubkey: payer, createdAt: createdAt,
                               text: comment, payload: .zap(sats: sats))
    }

    /// Amount in sats, read from the request's `amount` tag, then the receipt's
    /// own, then the invoice itself. zap.stream receipts routinely carry only
    /// the bolt11, so without the last rung most stream zaps render as "0".
    static func zapAmountSats(receiptTags: [[String]], requestTags: [[String]]) -> Int {
        func msats(_ tags: [[String]]) -> Int? {
            guard let raw = tags.first(where: { $0.count >= 2 && $0[0] == "amount" })?[1],
                  let value = Int(raw), value > 0 else { return nil }
            return value
        }
        if let msat = msats(requestTags) ?? msats(receiptTags) { return msat / 1000 }
        if let bolt11 = receiptTags.first(where: { $0.count >= 2 && $0[0] == "bolt11" })?[1] {
            return satsFromBolt11(bolt11) ?? 0
        }
        return 0
    }

    /// Sats from a BOLT-11 invoice, or nil when it states none.
    ///
    /// The reading lives in ``Bolt11`` because the wallet needs the same
    /// answer before you pay an invoice, and two copies of this would drift.
    static func satsFromBolt11(_ invoice: String) -> Int? { Bolt11.sats(invoice) }

    // MARK: - Private

    private struct ZapRequest {
        let pubkey: String
        let content: String
        let tags: [[String]]
    }

    /// The zap request lives as JSON inside the receipt's `description` tag.
    private static func zapRequest(from receiptTags: [[String]]) -> ZapRequest? {
        guard let description = receiptTags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              !description.isEmpty else { return nil }

        func parse(_ text: String) -> [String: Any]? {
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        // Some providers copy the request through a channel that leaves raw
        // control characters in the string, which JSONSerialization rejects.
        let json = parse(description) ?? parse(String(description.unicodeScalars.filter {
            $0.value >= 0x20 || $0 == "\n" || $0 == "\t"
        }))

        guard let json,
              let pubkey = json["pubkey"] as? String, !pubkey.isEmpty else { return nil }
        return ZapRequest(pubkey: pubkey,
                          content: json["content"] as? String ?? "",
                          tags: json["tags"] as? [[String]] ?? [])
    }
}

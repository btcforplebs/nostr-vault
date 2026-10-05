import Foundation
import Combine

/// Finds the zap receipts (and the zapped posts) behind wallet history rows,
/// so a row can say who a zap was from and what it was for.
///
/// Receipts are public kind-9735 events: incoming ones tag you with `p`,
/// outgoing ones with `P` (the sender). They are fetched once per history
/// page from your own relay, your feed relays and your inbox relays, then
/// matched to transactions by payment hash (`ZapReceipt.match`).
@MainActor
enum ZapHistoryService {

    struct Result {
        var details: [String: ZapDetail] = [:]   // transaction id -> zap
        var posts: [String: FeedNote] = [:]      // post id -> post
        var postEvents: [String: NostrEvent] = [:] // post id -> signed event
    }

    static func lookup(for transactions: [WalletTransaction], me: String) async -> Result {
        guard !me.isEmpty, !transactions.isEmpty else { return Result() }
        var result = Result()

        // 1. Wallets that return the zap request as the description need no
        //    network at all. The payer wrote that request, so it is believed
        //    only with a valid signature.
        for tx in transactions {
            if let zap = tx.zap, let json = zap.requestJSON, NostrEventVerifier.isValid(json: json),
               fits(zap, tx, me: me) {
                result.details[tx.id] = zap
            }
        }

        // 2. Receipts for the rest, over the time span the page covers.
        let unresolved = transactions.filter { result.details[$0.id] == nil }
        if !unresolved.isEmpty {
            let times = unresolved.map { Int($0.createdAt.timeIntervalSince1970) }
            // Receipts are published when the invoice is paid, which can be a
            // while after it was created.
            let since = (times.min() ?? 0) - 600
            let until = (times.max() ?? 0) + 3_600
            let filters: [[String: Any]] = [
                ["kinds": [9735], "#p": [me], "since": since, "until": until, "limit": 500],
                ["kinds": [9735], "#P": [me], "since": since, "until": until, "limit": 500],
            ]
            let events = await query(filters: filters, relays: relayURLs(me: me))
            var receipts: [ZapReceipt] = []
            for event in events {
                if let receipt = await trustedReceipt(event) { receipts.append(receipt) }
            }
            let byTx = Dictionary(uniqueKeysWithValues: unresolved.map { ($0.id, $0) })
            for (txId, detail) in ZapReceipt.match(unresolved, receipts) {
                guard result.details[txId] == nil, let tx = byTx[txId], fits(detail, tx, me: me) else { continue }
                result.details[txId] = detail
            }
        }

        // 3. The zapped posts, for the "on: …" line and tap-to-open.
        let postIds = Array(Set(result.details.values.compactMap(\.postId)))
        if !postIds.isEmpty {
            let events = await query(filters: [["ids": postIds, "limit": postIds.count]], relays: relayURLs(me: me))
            let wanted = Set(postIds)
            for e in events {
                guard let id = e["id"] as? String, wanted.contains(id), NostrEventVerifier.isValid(e),
                      let pubkey = e["pubkey"] as? String,
                      let kind = e["kind"] as? Int,
                      let createdAt = (e["created_at"] as? NSNumber)?.doubleValue else { continue }
                result.posts[id] = FeedNote(
                    id: id, pubkey: pubkey, content: e["content"] as? String ?? "",
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    tags: e["tags"] as? [[String]] ?? [], kind: kind
                )
                result.postEvents[id] = NostrEvent(
                    id: id, pubkey: pubkey, created_at: Int64(createdAt), kind: kind,
                    tags: e["tags"] as? [[String]] ?? [], content: e["content"] as? String ?? "",
                    sig: e["sig"] as? String ?? ""
                )
            }
        }

        // 4. Names and pictures for everyone involved.
        let people = transactions.compactMap { tx in result.details[tx.id]?.counterparty(me: me, direction: tx.direction) }
        let authors = result.posts.values.map(\.pubkey)
        NostrService.shared.fetchMissingProfiles(for: Array(Set(people + authors)))

        return result
    }

    /// A receipt is anyone's event until proven otherwise. Believed only when
    /// it is signed, the zap request inside it is signed, and it was
    /// published by the key the zapped person's own LNURL service names
    /// (`nostrPubkey`). Without the last check, anyone could copy a real
    /// receipt's bolt11 into one of their own and put any sender, post or
    /// comment ("refund me at …") on your payment.
    private static func trustedReceipt(_ event: [String: Any]) async -> ZapReceipt? {
        guard (event["kind"] as? Int) == 9735,
              let publisher = event["pubkey"] as? String,
              let tags = event["tags"] as? [[String]],
              let receipt = ZapReceipt(tags: tags),
              let requestJSON = receipt.detail.requestJSON,
              let recipient = receipt.detail.recipientPubkey,
              NostrEventVerifier.isValid(event),
              NostrEventVerifier.isValid(json: requestJSON),
              let authorized = await ZapValidationService.authorizedPublisher(for: recipient),
              authorized.lowercased() == publisher.lowercased() else { return nil }
        return receipt
    }

    /// A zap you received was made out to you; one you sent was made by you
    /// (or anonymously, from a throwaway key).
    private static func fits(_ zap: ZapDetail, _ tx: WalletTransaction, me: String) -> Bool {
        switch tx.direction {
        case .incoming: return zap.recipientPubkey?.lowercased() == me.lowercased()
        case .outgoing: return zap.isAnonymous || zap.senderPubkey.lowercased() == me.lowercased()
        }
    }

    /// Your relay first (it is local and holds what was sent to you), then
    /// the relays you read the feed from, then your published inbox relays.
    private static func relayURLs(me: String) -> [URL] {
        let config = ConfigService.shared.config
        var strings = [config.nostrURL]
        strings += config.activeFeedRelays.isEmpty ? ["wss://relay.primal.net", "wss://nos.lol"] : config.activeFeedRelays
        strings += NostrService.shared.relayLists[me] ?? []
        var seen = Set<String>()
        return strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted }
            .prefix(8)
            .compactMap { URL(string: $0) }
    }

    /// Sends `filters` to every relay and collects the events until each
    /// relay has sent EOSE or `timeout` passes. The article reader's
    /// highlights use it too.
    ///
    /// A relay is not trusted: only signature-checked events are kept, the
    /// first valid event per id wins (a forged copy reusing a real id cannot
    /// replace it), and each relay is held to the total `limit` it was asked
    /// for, since `limit` is only a request (Tron, #189).
    /// `onProgress`, when given, gets the events so far each time a relay
    /// finishes, on the main queue, before the final result.
    static func query(filters: [[String: Any]], relays: [URL], timeout: TimeInterval = 5,
                      onProgress: (([[String: Any]]) -> Void)? = nil) async -> [[String: Any]] {
        guard !relays.isEmpty else { return [] }
        let perRelayCap = filters.reduce(0) { $0 + (($1["limit"] as? Int) ?? 500) }
        return await withCheckedContinuation { continuation in
            var events: [String: [String: Any]] = [:]
            var pending = relays.count
            var done = false
            var clients: [WebSocketClient] = []
            var subscriptions: [AnyCancellable] = []
            let subId = "zaphist-\(UUID().uuidString.prefix(8))"

            func finish() {
                guard !done else { return }
                done = true
                clients.forEach { $0.disconnect() }
                subscriptions.removeAll()
                continuation.resume(returning: Array(events.values))
            }

            func relayFinished() {
                pending -= 1
                if pending <= 0 { finish() } else if !events.isEmpty { onProgress?(Array(events.values)) }
            }

            for url in relays {
                let client = WebSocketClient()
                client.isTemporary = true
                clients.append(client)
                var relayDone = false
                var received = 0

                client.messageSubject
                    .receive(on: DispatchQueue.main)
                    .sink { message in
                        guard !done, !relayDone,
                              let data = message.data(using: .utf8),
                              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              array.count >= 2,
                              let type = array[0] as? String,
                              (array[1] as? String) == subId else { return }
                        if type == "EVENT", array.count >= 3,
                           let event = array[2] as? [String: Any],
                           let id = event["id"] as? String {
                            received += 1
                            if received > perRelayCap {
                                // Past what it was asked for: stop listening.
                                relayDone = true
                                client.disconnect()
                                relayFinished()
                                return
                            }
                            if events[id] == nil, NostrEventVerifier.isValid(event) {
                                events[id] = event
                            }
                        } else if type == "EOSE" || type == "CLOSED" {
                            relayDone = true
                            relayFinished()
                        }
                    }
                    .store(in: &subscriptions)

                client.$connectionState
                    .removeDuplicates()
                    .dropFirst()
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        guard !done, !relayDone else { return }
                        switch state {
                        case .connected:
                            let req: [Any] = ["REQ", subId] + filters
                            if let data = try? JSONSerialization.data(withJSONObject: req),
                               let str = String(data: data, encoding: .utf8) {
                                client.send(text: str)
                            }
                        case .error, .disconnected:
                            relayDone = true
                            relayFinished()
                        default:
                            break
                        }
                    }
                    .store(in: &subscriptions)

                client.connect(url: url)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}

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
    }

    static func lookup(for transactions: [WalletTransaction], me: String) async -> Result {
        guard !me.isEmpty, !transactions.isEmpty else { return Result() }
        var result = Result()

        // 1. Wallets that return the zap request as the description need no
        //    network at all.
        for tx in transactions {
            if let zap = tx.zap { result.details[tx.id] = zap }
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
            let receipts = events.compactMap { ($0["tags"] as? [[String]]).flatMap(ZapReceipt.init(tags:)) }
            result.details.merge(ZapReceipt.match(unresolved, receipts)) { current, _ in current }
        }

        // 3. The zapped posts, for the "on: …" line and tap-to-open.
        let postIds = Array(Set(result.details.values.compactMap(\.postId)))
        if !postIds.isEmpty {
            let events = await query(filters: [["ids": postIds, "limit": postIds.count]], relays: relayURLs(me: me))
            for e in events {
                guard let id = e["id"] as? String,
                      let pubkey = e["pubkey"] as? String,
                      let kind = e["kind"] as? Int,
                      let createdAt = (e["created_at"] as? NSNumber)?.doubleValue else { continue }
                result.posts[id] = FeedNote(
                    id: id, pubkey: pubkey, content: e["content"] as? String ?? "",
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    tags: e["tags"] as? [[String]] ?? [], kind: kind
                )
            }
        }

        // 4. Names and pictures for everyone involved.
        let people = transactions.compactMap { tx in result.details[tx.id]?.counterparty(me: me, direction: tx.direction) }
        let authors = result.posts.values.map(\.pubkey)
        NostrService.shared.fetchMissingProfiles(for: Array(Set(people + authors)))

        return result
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

    /// Sends `filters` to every relay and collects the events (deduplicated
    /// by id) until each relay has sent EOSE or `timeout` passes.
    private static func query(filters: [[String: Any]], relays: [URL], timeout: TimeInterval = 5) async -> [[String: Any]] {
        guard !relays.isEmpty else { return [] }
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
                if pending <= 0 { finish() }
            }

            for url in relays {
                let client = WebSocketClient()
                client.isTemporary = true
                clients.append(client)
                var relayDone = false

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
                            events[id] = event
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

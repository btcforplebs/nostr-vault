import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// The newest signed kind 10050 for `pubkey` across the blastr relays, the
    /// account's cached outbox relays and `alsoAsk`, or nil if none answered
    /// within the timeout. Asks fresh rather than trusting `dmRelayLists`,
    /// which is cached across launches and would let a device adopt its own
    /// stale copy.
    func fetchNewestDMRelayList(for pubkey: String, alsoAsk: [String], timeout: TimeInterval = 6) async -> (relays: [String], createdAt: Int64)? {
        guard let winner = await fetchNewestReplaceable(kind: 10050, for: pubkey, alsoAsk: alsoAsk, timeout: timeout) else { return nil }
        return (ProfileRepository.parseDMRelayListTags(winner.tags), winner.created_at)
    }

    /// The newest signed replaceable event of `kind` by `pubkey` across the
    /// blastr relays, the account's cached outbox relays and `alsoAsk`, or nil
    /// if none answered within the timeout. Asks fresh: the profile caches can
    /// hold a list that was replaced long ago.
    /// With `dTag`, an addressable event (kinds 30000-39999) at that `d` tag.
    func fetchNewestReplaceable(kind: Int, for pubkey: String, alsoAsk: [String], dTag: String? = nil, timeout: TimeInterval = 6) async -> NostrEvent? {
        await lookupNewestReplaceable(kind: kind, for: pubkey, alsoAsk: alsoAsk, dTag: dTag, timeout: timeout).event
    }

    /// `fetchNewestReplaceable`, also saying whether "none" was confirmed:
    /// every relay asked answered EOSE for this request without the event.
    func lookupNewestReplaceable(kind: Int, for pubkey: String, alsoAsk: [String], dTag: String? = nil, timeout: TimeInterval = 6) async -> ReplaceableLookup<NostrEvent> {
        var urls = ConfigService.shared.config.writeRelays
        for extra in alsoAsk + (outboxRelays[pubkey] ?? []) where !urls.contains(extra) {
            urls.append(extra)
        }
        let targets = urls.filter { !Self.isLoopbackRelay($0) }.compactMap { URL(string: $0) }
        guard !targets.isEmpty else { return ReplaceableLookup(event: nil, asked: 0, answered: 0) }

        return await withCheckedContinuation { (continuation: CheckedContinuation<ReplaceableLookup<NostrEvent>, Never>) in
            let lock = NSLock()
            var best: NostrEvent?
            // Relays done (EOSE or CLOSED), each counted once; only an EOSE
            // for the request sent there counts as an answer.
            var finished = Set<Int>()
            var answered = Set<Int>()
            var resumed = false
            var clients: [WebSocketClient] = []
            var subs = Set<AnyCancellable>()

            func finish() {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                let result = ReplaceableLookup(event: best, asked: targets.count, answered: answered.count)
                lock.unlock()
                DispatchQueue.main.async {
                    clients.forEach { $0.disconnect() }
                    subs.removeAll()
                }
                continuation.resume(returning: result)
            }

            DispatchQueue.main.async {
                for (index, url) in targets.enumerated() {
                    let client = WebSocketClient()
                    client.isTemporary = true
                    clients.append(client)
                    let subId = "repl-\(UUID().uuidString.prefix(6))"
                    client.messageSubject
                        .sink { message in
                            guard let data = message.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                  let type = json.first as? String else { return }
                            if type == "EVENT", let dict = json[safe: 2] as? [String: Any],
                               let raw = try? JSONSerialization.data(withJSONObject: dict),
                               let event = try? JSONDecoder().decode(NostrEvent.self, from: raw),
                               event.kind == kind, event.pubkey == pubkey,
                               dTag == nil || event.tags.contains(where: { $0.count >= 2 && $0[0] == "d" && $0[1] == dTag }),
                               let str = String(data: raw, encoding: .utf8),
                               NostrEventVerifier.isValid(json: str) {
                                lock.lock()
                                if best == nil || event.created_at > best!.created_at { best = event }
                                lock.unlock()
                            } else if type == "EOSE" || type == "CLOSED" {
                                lock.lock()
                                if type == "EOSE", json[safe: 1] as? String == subId, !finished.contains(index) {
                                    answered.insert(index)
                                }
                                finished.insert(index)
                                let all = finished.count >= targets.count
                                lock.unlock()
                                if all { finish() }
                            }
                        }
                        .store(in: &subs)
                    client.$connectionState
                        .sink { state in
                            guard state == .connected else { return }
                            var filter: [String: Any] = ["kinds": [kind], "authors": [pubkey], "limit": 1]
                            if let dTag { filter["#d"] = [dTag] }
                            let req = ["REQ", subId, filter] as [Any]
                            if let data = try? JSONSerialization.data(withJSONObject: req),
                               let str = String(data: data, encoding: .utf8) {
                                client.send(text: str)
                            }
                        }
                        .store(in: &subs)
                    client.connect(url: url)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
            }
        }
    }

    /// The newest `limit` notes (kind 1) by `author`, newest first, from the
    /// local relay, the feed relays and the author's outbox relays. Empty if
    /// none answered within the timeout. For the small profile card, which
    /// must never wait on a slow relay to offer Follow.
    func fetchRecentNotes(author: String, limit: Int = 3, timeout: TimeInterval = 6) async -> [NostrEvent] {
        var urls: [String] = []
        if RelayProcessManager.shared.isRunning, !RelayProcessManager.shared.isBooting {
            urls.append(ConfigService.shared.config.nostrURL)
        }
        let feedRelays = ConfigService.shared.config.activeFeedRelays
        urls += (feedRelays.isEmpty ? ["wss://relay.primal.net", "wss://relay.nos.social"] : Array(feedRelays.prefix(3)))
        urls += (outboxRelays[author] ?? []).prefix(3)
        var seen = Set<String>()
        let targets = urls.filter { seen.insert($0).inserted }.compactMap { URL(string: $0) }
        guard !targets.isEmpty else { return [] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[NostrEvent], Never>) in
            let lock = NSLock()
            var found: [String: NostrEvent] = [:]
            var finished = Set<Int>()
            var resumed = false
            var clients: [WebSocketClient] = []
            var subs = Set<AnyCancellable>()

            func finish() {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                let notes = found.values.sorted { $0.created_at > $1.created_at }.prefix(limit)
                lock.unlock()
                DispatchQueue.main.async {
                    clients.forEach { $0.disconnect() }
                    subs.removeAll()
                }
                continuation.resume(returning: Array(notes))
            }

            DispatchQueue.main.async {
                for (index, url) in targets.enumerated() {
                    let client = WebSocketClient()
                    client.isTemporary = true
                    clients.append(client)
                    let subId = "recent-\(UUID().uuidString.prefix(6))"
                    client.messageSubject
                        .sink { message in
                            guard let data = message.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                  let type = json.first as? String else { return }
                            if type == "EVENT", let dict = json[safe: 2] as? [String: Any],
                               let raw = try? JSONSerialization.data(withJSONObject: dict),
                               let event = try? JSONDecoder().decode(NostrEvent.self, from: raw),
                               event.kind == 1, event.pubkey == author,
                               let str = String(data: raw, encoding: .utf8),
                               NostrEventVerifier.isValid(json: str) {
                                lock.lock()
                                found[event.id] = event
                                lock.unlock()
                            } else if type == "EOSE" || type == "CLOSED" {
                                lock.lock()
                                finished.insert(index)
                                let all = finished.count >= targets.count
                                lock.unlock()
                                if all { finish() }
                            }
                        }
                        .store(in: &subs)
                    client.$connectionState
                        .sink { state in
                            guard state == .connected else { return }
                            let req = ["REQ", subId, ["kinds": [1], "authors": [author], "limit": limit]] as [Any]
                            if let data = try? JSONSerialization.data(withJSONObject: req),
                               let str = String(data: data, encoding: .utf8) {
                                client.send(text: str)
                            }
                        }
                        .store(in: &subs)
                    client.connect(url: url)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
            }
        }
    }

    /// `target`'s follower count from Vertex, the source npub.world uses. Nil
    /// when Vertex can't answer: no local key (a bunker would be asked to sign
    /// for every profile opened), no credits, or no answer in time. The
    /// request is signed by the active account and names `target`.
    func fetchVertexFollowerCount(target: String, timeout: TimeInterval = 6) async -> Int? {
        let now = Date()
        if let cached = vertexCache.followers(for: target, now: now) { return cached }
        guard vertexCache.shouldAsk(now: now),
              ConfigService.shared.config.activeSigningMode() == "local",
              let url = URL(string: VertexReputation.relayURL),
              let request = signEvent(kind: VertexReputation.requestKind, content: "",
                                      tags: VertexReputation.requestTags(target: target)),
              let requestData = try? JSONEncoder().encode(request),
              let requestDict = try? JSONSerialization.jsonObject(with: requestData) else { return nil }
        let requestId = request.id

        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<VertexReputation.Reply?, Never>) in
            let lock = NSLock()
            var resumed = false
            let client = WebSocketClient()
            client.isTemporary = true
            var subs = Set<AnyCancellable>()

            func finish(_ reply: VertexReputation.Reply?) {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                DispatchQueue.main.async {
                    client.disconnect()
                    subs.removeAll()
                }
                continuation.resume(returning: reply)
            }

            DispatchQueue.main.async {
                let subId = "vertex-\(UUID().uuidString.prefix(6))"
                client.messageSubject
                    .sink { message in
                        guard let data = message.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              json.first as? String == "EVENT",
                              let dict = json[safe: 2] as? [String: Any],
                              let raw = try? JSONSerialization.data(withJSONObject: dict),
                              let event = try? JSONDecoder().decode(NostrEvent.self, from: raw),
                              let str = String(data: raw, encoding: .utf8),
                              NostrEventVerifier.isValid(json: str),
                              let reply = VertexReputation.reply(
                                kind: event.kind, pubkey: event.pubkey, tags: event.tags,
                                content: event.content, requestId: requestId, target: target
                              ) else { return }
                        finish(reply)
                    }
                    .store(in: &subs)
                client.$connectionState
                    .sink { state in
                        guard state == .connected else { return }
                        // Listen first, so a fast answer isn't missed.
                        let filter: [String: Any] = [
                            "kinds": [VertexReputation.resultKind, VertexReputation.feedbackKind],
                            "#e": [requestId],
                        ]
                        for message in [["REQ", subId, filter], ["EVENT", requestDict]] as [[Any]] {
                            if let data = try? JSONSerialization.data(withJSONObject: message),
                               let str = String(data: data, encoding: .utf8) {
                                client.send(text: str)
                            }
                        }
                    }
                    .store(in: &subs)
                client.connect(url: url)
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            }
        }

        // No answer in time says nothing about credits; only a reply is kept.
        guard let reply else { return nil }
        vertexCache.record(reply, for: target, now: Date())
        if case .followers(let count) = reply { return count }
        return nil
    }

    /// Ids of the active account's own reactions (kind 7) to `noteId`, from
    /// the account's relay and the blastr relays. For removing a like saved
    /// before its event id was kept.
    func fetchOwnReactionIds(to noteId: String, timeout: TimeInterval = 5) async -> [String] {
        let pubkey = activeHexPubkey
        guard !pubkey.isEmpty else { return [] }
        var urls = ConfigService.shared.config.writeRelays
        let own = ConfigService.shared.config.nostrURL
        if !own.isEmpty, !urls.contains(own) { urls.append(own) }
        let targets = urls.filter { !Self.isLoopbackRelay($0) }.compactMap { URL(string: $0) }
        guard !targets.isEmpty else { return [] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let lock = NSLock()
            var ids = Set<String>()
            var finished = Set<Int>()
            var resumed = false
            var clients: [WebSocketClient] = []
            var subs = Set<AnyCancellable>()

            func finish() {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                let result = Array(ids)
                lock.unlock()
                DispatchQueue.main.async {
                    clients.forEach { $0.disconnect() }
                    subs.removeAll()
                }
                continuation.resume(returning: result)
            }

            DispatchQueue.main.async {
                for (index, url) in targets.enumerated() {
                    let client = WebSocketClient()
                    client.isTemporary = true
                    clients.append(client)
                    let subId = "myrx-\(UUID().uuidString.prefix(6))"
                    client.messageSubject
                        .sink { message in
                            guard let data = message.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                  let type = json.first as? String else { return }
                            if type == "EVENT", let dict = json[safe: 2] as? [String: Any],
                               dict["kind"] as? Int == 7, dict["pubkey"] as? String == pubkey,
                               let id = dict["id"] as? String,
                               let tags = dict["tags"] as? [[String]],
                               tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == noteId }),
                               let raw = try? JSONSerialization.data(withJSONObject: dict),
                               let str = String(data: raw, encoding: .utf8),
                               NostrEventVerifier.isValid(json: str) {
                                lock.lock()
                                ids.insert(id)
                                lock.unlock()
                            } else if type == "EOSE" || type == "CLOSED" {
                                lock.lock()
                                finished.insert(index)
                                let all = finished.count >= targets.count
                                lock.unlock()
                                if all { finish() }
                            }
                        }
                        .store(in: &subs)
                    client.$connectionState
                        .sink { state in
                            guard state == .connected else { return }
                            let req = ["REQ", subId, ["kinds": [7], "authors": [pubkey], "#e": [noteId], "limit": 20]] as [Any]
                            if let data = try? JSONSerialization.data(withJSONObject: req),
                               let str = String(data: data, encoding: .utf8) {
                                client.send(text: str)
                            }
                        }
                        .store(in: &subs)
                    client.connect(url: url)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
            }
        }
    }
}

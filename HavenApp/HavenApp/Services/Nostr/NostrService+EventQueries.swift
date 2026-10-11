import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// The event a quote reference points at, if this relay already holds it.
    /// Accepts either a 64-hex event id or an `"naddr:<kind>:<pubkey>:<d-tag>"`
    /// coordinate, matching `FeedService.findNote(id:)`.
    func storedEvent(matching identifier: String) -> NostrEvent? {
        // `events` is sorted newest first, so for an addressable event the first
        // match is the current one.
        let matcher = QuoteReference.matcher(for: identifier)
        return events.first {
            matcher.matches(id: $0.id, kind: $0.kind, pubkey: $0.pubkey, tags: $0.tags)
        }
    }

    /// Requests a quoted event this relay does not hold, from the local relay and
    /// the configured feed relays. Safe to call from a view's `onAppear`: each
    /// identifier is requested once per session.
    func fetchQuotedEvent(_ identifier: String) {
        guard storedEvent(matching: identifier) == nil,
              !quotedEventsInFlight.contains(identifier) else { return }
        quotedEventsInFlight.insert(identifier)

        let config = ConfigService.shared.config
        var urls = [config.nostrURL].compactMap { URL(string: $0) }
        let externals = config.readRelays
        urls.append(contentsOf: externals.compactMap { URL(string: $0) })
        guard !urls.isEmpty else { return }

        if let (kind, pubkey, dTag) = QuoteReference.parseCoordinate(identifier) {
            fetchAddressableEvent(kind: kind, pubkey: pubkey, dTag: dTag, from: urls)
        } else {
            fetchNotesByIds([identifier], from: urls)
        }
    }

    /// Fetches an addressable (NIP-33) event by its coordinate. `fetchNotesByIds`
    /// cannot serve these — a coordinate is not an event id, so an `ids` filter
    /// would match nothing.
    private func fetchAddressableEvent(kind: Int, pubkey: String, dTag: String, from relayURLs: [URL]) {
        let filter: [String: Any] = ["kinds": [kind], "authors": [pubkey], "#d": [dTag], "limit": 1]

        for url in relayURLs {
            let urlString = url.absoluteString
            if isLocalRelay(url) && !isLocalRelayReady { continue }

            let subId = "addr-\(UUID().uuidString.prefix(6))"
            let req = ["REQ", subId, filter] as [Any]
            guard let data = try? JSONSerialization.data(withJSONObject: req),
                  let reqString = String(data: data, encoding: .utf8) else { continue }

            if let existing = clients[urlString], existing.connectionState == .connected {
                existing.send(text: reqString)
                continue
            }

            let client = WebSocketClient()
            client.isTemporary = true
            // Held until it disconnects. Nothing else kept it: it was freed when this
            // function returned, before `connect` ran, so no request was ever sent.
            trackTemporaryClient(client)
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    guard let client = client else { return }
                    client.send(text: reqString)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { client.disconnect() }
                }
                .store(in: &cancellables)
            client.connect(url: url)
        }
    }

    /// Fetch specific events by their IDs from the given relays.
    /// Results are merged into the shared `events` array via the normal processing pipeline.
    func fetchNotesByIds(_ ids: [String], from relayURLs: [URL]) {
        guard !ids.isEmpty else { return }

        let filter: [String: Any] = ["ids": ids]

        for url in relayURLs {
            let urlString = url.absoluteString
            if isLocalRelay(url) && !isLocalRelayReady { continue }

            // Reuse existing connected client if available
            if let existing = clients[urlString], existing.connectionState == .connected {
                let subId = "byid-\(UUID().uuidString.prefix(6))"
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let str = String(data: data, encoding: .utf8) {
                    existing.send(text: str)
                }
                continue
            }

            let client = WebSocketClient()
            client.isTemporary = true
            // Held until it disconnects. Nothing else kept it: it was freed when this
            // function returned, before `connect` ran, so no request was ever sent.
            trackTemporaryClient(client)
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            let safeFilter = UncheckedSendable(value: filter)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    guard let client = client else { return }
                    let subId = "byid-\(UUID().uuidString.prefix(6))"
                    let req = ["REQ", subId, safeFilter.value] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    /// One page of older events of the given kinds, for a list that pages on
    /// its own (the Vault tab's Articles and Highlights). It runs on its own
    /// connection and leaves the shared fetch state alone, so it neither moves
    /// the Notes list's paging nor clears `isFetching` under it. `done` gets
    /// how many events came back, 0 meaning there is nothing older, or nil
    /// when no relay could be asked or none answered.
    func fetchOlder(kinds: [Int], authors: [String], until: Int64, limit: Int = 50,
                    from relayURLs: [URL], done: @escaping (Int?) -> Void) {
        let urls = relayURLs.filter { !isLocalRelay($0) || isLocalRelayReady }
        guard !urls.isEmpty, !authors.isEmpty else { done(nil); return }

        let filter: [String: Any] = ["kinds": kinds, "authors": authors, "until": until, "limit": limit]
        let safeFilter = UncheckedSendable(value: filter)
        let subId = "older-\(UUID().uuidString.prefix(6))"
        let page = OlderPage(pending: urls.count)
        let finish: () -> Void = {
            guard !page.finished else { return }
            page.finished = true
            page.clients.forEach { $0.disconnect() }
            page.clients.removeAll()
            done(page.pending == urls.count ? nil : page.ids.count)
        }
        // A relay that never answers mustn't leave the button spinning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }

        for url in urls {
            let urlString = url.absoluteString
            let client = WebSocketClient()
            client.isTemporary = true
            trackTemporaryClient(client)
            page.clients.append(client)
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self, weak client] message in
                    guard let data = message.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          json.count >= 2, json[1] as? String == subId,
                          let type = json[0] as? String else { return }
                    if type == "EVENT" {
                        let id = (json[safe: 2] as? [String: Any])?["id"] as? String
                        DispatchQueue.main.async { if let id { page.ids.insert(id) } }
                        self?.processMessage(message, from: urlString)
                    } else if type == "EOSE" || type == "CLOSED" {
                        DispatchQueue.main.async {
                            client?.disconnect()
                            page.pending -= 1
                            if page.pending <= 0 { finish() }
                        }
                    }
                }
                .store(in: &cancellables)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    let req = ["REQ", subId, safeFilter.value] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client?.send(text: str)
                    }
                }
                .store(in: &cancellables)
            client.connect(url: url)
        }
    }

    /// Fetches zap receipts (kind 9735) with a larger limit to cover more history.
    /// `tagFilter` narrows the request, e.g. `["#P": [me]]` for zaps you sent.
    func fetchZapReceipts(from relayURLs: [URL], limit: Int = 1000, tagFilter: [String: [String]] = [:]) {
        var filter: [String: Any] = ["kinds": [9735], "limit": limit]
        for (key, values) in tagFilter { filter[key] = values }

        for url in relayURLs {
            let urlString = url.absoluteString
            if isLocalRelay(url) && !isLocalRelayReady { continue }

            if let existing = clients[urlString], existing.connectionState == .connected {
                let subId = "zaps-\(UUID().uuidString.prefix(6))"
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let str = String(data: data, encoding: .utf8) {
                    existing.send(text: str)
                }
                continue
            }

            let client = WebSocketClient()
            client.isTemporary = true
            // Held until it disconnects. Nothing else kept it: it was freed when this
            // function returned, before `connect` ran, so no request was ever sent.
            trackTemporaryClient(client)
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            let safeFilter = UncheckedSendable(value: filter)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    guard let client = client else { return }
                    let subId = "zaps-\(UUID().uuidString.prefix(6))"
                    let req = ["REQ", subId, safeFilter.value] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    func fetchCount(from relayURLs: [URL], filter: [String: Any] = [:]) async -> Int? {
        #if DEBUG
        print("NostrService: Starting aggregate fetchCount for \(relayURLs.count) relays")
        #endif
        var totalCount: Int? = nil
        var responsesReceived = 0

        let safeFilter = UncheckedSendable(value: filter)

        await withTaskGroup(of: Int?.self) { group in
            for url in relayURLs {
                group.addTask {
                    let filter = safeFilter.value
                    let urlString = url.absoluteString
                    let relayTag = url.lastPathComponent.isEmpty ? "outbox" : url.lastPathComponent

                    #if DEBUG
                    print("NostrService [\(relayTag)]: Task started")
                    #endif

                    let (client, isNew) = await MainActor.run { () -> (WebSocketClient?, Bool) in
                        if let existing = self.clients[urlString] {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Using existing client")
                            #endif
                            return (existing, false)
                        } else {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Creating new client")
                            #endif
                            let newClient = WebSocketClient()
                            newClient.isTemporary = true
                            return (newClient, true)
                        }
                    }

                    guard let client = client else {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Failed to get client")
                        #endif
                        return nil
                    }

                    // 1. Wait for connection if needed
                    if client.connectionState != .connected {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Not connected. Connecting now...")
                        #endif
                        client.connect(url: url)

                        var cancellable: AnyCancellable?
                        let didConnect = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                            var hasResumed = false

                            cancellable = client.$connectionState
                                .first(where: { $0 == .connected || $0 == .error })
                                .timeout(.seconds(5), scheduler: DispatchQueue.main)
                                .sink { completion in
                                    if !hasResumed {
                                        hasResumed = true
                                        if case .failure = completion {
                                            #if DEBUG
                                            print("NostrService [\(relayTag)]: Connection timeout")
                                            #endif
                                        }
                                        continuation.resume(returning: false)
                                    }
                                } receiveValue: { state in
                                    if !hasResumed {
                                        hasResumed = true
                                        #if DEBUG
                                        print("NostrService [\(relayTag)]: Connection state reached: \(state)")
                                        #endif
                                        continuation.resume(returning: state == .connected)
                                    }
                                }
                        }
                        _ = cancellable // Hold it until await finishes

                        if !didConnect {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Failed to connect during fetchCount")
                            #endif
                            if isNew { await MainActor.run { client.disconnect() } }
                            return nil
                        }
                    }

                    // 2. Send COUNT and wait for response
                    let subscriptionId = "count-\(UUID().uuidString.prefix(6))"
                    #if DEBUG
                    print("NostrService [\(relayTag)]: Sending COUNT with subId: \(subscriptionId)")
                    #endif

                    var messageCancellable: AnyCancellable?
                    let countResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                        var hasResumed = false

                        messageCancellable = client.messageSubject
                            .timeout(.seconds(10), scheduler: DispatchQueue.main)
                            .sink { completion in
                                if !hasResumed {
                                    hasResumed = true
                                    #if DEBUG
                                    print("NostrService [\(relayTag)]: COUNT response timeout or completion")
                                    #endif
                                    continuation.resume(returning: nil)
                                }
                            } receiveValue: { msg in
                                guard let data = msg.data(using: .utf8),
                                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                      json.count >= 3,
                                      let type = json[0] as? String,
                                      let subId = json[1] as? String,
                                      subId == subscriptionId else {
                                    return
                                }

                                if type == "COUNT" {
                                    if let payload = json[2] as? [String: Any],
                                       let rawCount = payload["count"] {
                                        let extractedCount: Int
                                        if let intVal = rawCount as? Int {
                                            extractedCount = intVal
                                        } else if let doubleVal = rawCount as? Double {
                                            extractedCount = Int(doubleVal)
                                        } else if let numberVal = rawCount as? NSNumber {
                                            extractedCount = numberVal.intValue
                                        } else if let stringVal = rawCount as? String, let intVal = Int(stringVal) {
                                            extractedCount = intVal
                                        } else {
                                            extractedCount = 0
                                        }
                                        
                                        if !hasResumed {
                                            hasResumed = true
                                            #if DEBUG
                                            print("NostrService [\(relayTag)]: Received COUNT, count: \(extractedCount)")
                                            #endif
                                            continuation.resume(returning: extractedCount)
                                        }
                                    }
                                }
                            }

                        // Send the actual COUNT request
                        let req = ["COUNT", subscriptionId, filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqString = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqString)
                        } else {
                            if !hasResumed {
                                hasResumed = true
                                continuation.resume(returning: nil)
                            }
                        }
                    }
                    _ = messageCancellable // Hold it until await finishes

                    if isNew {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Disconnecting temporary client")
                        #endif
                        await MainActor.run { client.disconnect() }
                    }

                    #if DEBUG
                    print("NostrService [\(relayTag)]: Returning count: \(String(describing: countResult))")
                    #endif
                    return countResult
                }
            }

            for await count in group {
                if let count = count {
                     totalCount = (totalCount ?? 0) + count
                     responsesReceived += 1
                }
            }
        }

        // Only return an aggregate count when ALL endpoints responded.
        // Partial responses cause wild fluctuations (e.g. 3 vs 21,000)
        // because failed endpoints are silently skipped.
        guard responsesReceived == relayURLs.count else {
            #if DEBUG
            print("NostrService: Only \(responsesReceived)/\(relayURLs.count) endpoints responded — returning nil to avoid partial count")
            #endif
            return nil
        }

        #if DEBUG
        print("NostrService: Final aggregated count: \(String(describing: totalCount))")
        #endif
        return totalCount
    }
}

/// The running tally of one `fetchOlder` page. Touched only on the main queue.
private final class OlderPage: @unchecked Sendable {
    var pending: Int
    var ids = Set<String>()
    var finished = false
    /// Closed when the page finishes, timeout included.
    var clients: [WebSocketClient] = []
    init(pending: Int) { self.pending = pending }
}

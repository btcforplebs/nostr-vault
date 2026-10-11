import Foundation
import Combine

extension DMService {
    /// Fetch DMs from the user's known external relays (the Read relays, then
    /// the DM inbox) to catch any gift wraps not yet imported by the Go relay.
    func fetchFromExternalRelays() {
        let ownPubkey = loadedAccountPubkey
        guard !ownPubkey.isEmpty else { return }
        backfillSentCopiesIfNeeded()

        let generation = self.switchGeneration

        var relays = ConfigService.shared.config.readRelays

        // Include own DM inbox relays: your sent copies from other devices
        // land there, as do messages to you.
        for relay in ownDMInboxRelays() where !relays.contains(relay) {
            relays.append(relay)
        }
        if let ownDMRelays = NostrService.shared.dmRelayLists[ownPubkey] {
            for relay in ownDMRelays where !relays.contains(relay) && !NostrService.isLoopbackRelay(relay) {
                relays.append(relay)
            }
        }
        // And your general (kind 10002) read relays: builds before the DM
        // inbox list sent your own copies there when that list happened to be
        // found first, so this is where those messages are.
        if let ownReadRelays = NostrService.shared.relayLists[ownPubkey] {
            for relay in ownReadRelays where !relays.contains(relay) && !NostrService.isLoopbackRelay(relay) {
                relays.append(relay)
            }
        }

        // Include counterpart DM relays — messages to us are published there
        let maxRelays = 15
        for conversation in conversations {
            guard relays.count < maxRelays else { break }
            if let counterpartRelays = NostrService.shared.dmRelayLists[conversation.id] {
                for relay in counterpartRelays where !relays.contains(relay) {
                    relays.append(relay)
                    if relays.count >= maxRelays { break }
                }
            }
        }

        #if DEBUG
        print("🌐 Fetching DMs from \(relays.count) external relays...")
        #endif

        for urlStr in relays {
            guard let url = URL(string: urlStr) else { continue }

            let client = WebSocketClient()
            client.isTemporary = true
            externalClients.append(client)

            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    guard let self = self else { return }
                    // Discard if account switched since this fetch started
                    DispatchQueue.main.async {
                        guard self.switchGeneration == generation else { return }
                        self.processExternalMessage(message, forAccount: ownPubkey)
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    guard let self = self, let client = client else { return }
                    guard self.switchGeneration == generation else {
                        client.disconnect()
                        return
                    }
                    if state == .connected {
                        // Use 1-hour overlap for clock drift safety
                        let since = max(0, self.lastExternalFetchTimestamp - 3600)

                        // NIP-17 gift wraps. created_at is randomized up to 2
                        // days into the past, so the 1-hour overlap above would
                        // miss most new ones — floor the window at 2 days.
                        var nip17Filter: [String: Any] = [
                            "kinds": [1059],
                            "#p": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 {
                            let wrapFloor = Int64(Date().timeIntervalSince1970) - (2 * 24 * 3600 + 60)
                            nip17Filter["since"] = min(since, wrapFloor)
                        }
                        let req1 = ["REQ", "ext-nip17-\(UUID().uuidString.prefix(6))", nip17Filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req1),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // NIP-04 legacy DMs (received)
                        var nip04FilterReceived: [String: Any] = [
                            "kinds": [4],
                            "#p": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 { nip04FilterReceived["since"] = since }
                        let req2 = ["REQ", "ext-nip04-in-\(UUID().uuidString.prefix(6))", nip04FilterReceived] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req2),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // NIP-04 legacy DMs (sent)
                        var nip04FilterSent: [String: Any] = [
                            "kinds": [4],
                            "authors": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 { nip04FilterSent["since"] = since }
                        let req3 = ["REQ", "ext-nip04-out-\(UUID().uuidString.prefix(6))", nip04FilterSent] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req3),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // Disconnect after timeout and update fetch timestamp
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            client.disconnect()
                            self?.externalClients.removeAll { $0 === client }
                            // Update timestamp and tear down injection clients when the last external client disconnects
                            if self?.externalClients.isEmpty == true {
                                self?.lastExternalFetchTimestamp = Int64(Date().timeIntervalSince1970)
                                self?.disconnectInjectionClients()
                            }
                        }
                    }
                }
                .store(in: &cancellables)

            // A relay that never connects (or errors) used to stay in
            // externalClients forever: the cleanup above only runs after a
            // connect, so the list never emptied and the fetch timestamp
            // never advanced — every later fetch reused a days-old window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.externalClients.contains(where: { $0 === client }) else { return }
                client.disconnect()
                self.externalClients.removeAll { $0 === client }
                if self.externalClients.isEmpty {
                    self.lastExternalFetchTimestamp = Int64(Date().timeIntervalSince1970)
                    self.disconnectInjectionClients()
                }
            }

            client.connect(url: url)
        }
    }
    private func backfillSentCopiesIfNeeded() {
        let ownPubkey = loadedAccountPubkey
        let key = "dm.sentCopyBackfill.v1.\(ownPubkey)"
        guard !ownPubkey.isEmpty, !backfillRunning, !UserDefaults.standard.bool(forKey: key) else { return }
        backfillRunning = true
        let generation = switchGeneration

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.backfillRunning = false }
            let fresh = await NostrService.shared.fetchNewestReplaceable(kind: 10002, for: ownPubkey, alsoAsk: self.ownDMInboxRelays())
            guard self.switchGeneration == generation else { return }
            var relays: [String] = []
            if let fresh {
                let parsed = ProfileRepository.parseRelayListTags(fresh.tags)
                relays += parsed.inbox + parsed.write
            }
            relays += NostrService.shared.relayLists[ownPubkey] ?? []
            relays += self.ownDMInboxRelays()
            var seen = Set<String>()
            relays = relays
                .map { HavenConfig.normalizedRelayURL($0) }
                .filter { !$0.isEmpty && !NostrService.isLoopbackRelay($0) && seen.insert($0.lowercased()).inserted }
            #if DEBUG
            print("🧺 DM sent-copy catch-up from \(relays.count) relays (fresh 10002: \(fresh != nil))")
            #endif

            await withTaskGroup(of: Void.self) { group in
                for urlStr in relays {
                    guard let url = URL(string: urlStr) else { continue }
                    group.addTask { @MainActor in
                        await self.backfillFetch(url: url, ownPubkey: ownPubkey, generation: generation)
                    }
                }
            }
            guard self.switchGeneration == generation, fresh != nil else { return }
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    /// Asks one relay for every gift wrap addressed to you, no time window,
    /// and hands each to the normal external-message path (which shows it
    /// and stores it in the local relay). Returns at EOSE or after 12s.
    @MainActor
    private func backfillFetch(url: URL, ownPubkey: String, generation: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let client = WebSocketClient()
            client.isTemporary = true
            var subs = Set<AnyCancellable>()
            var finished = false
            let subId = "bf-\(UUID().uuidString.prefix(6))"
            func finish() {
                guard !finished else { return }
                finished = true
                client.disconnect()
                subs.removeAll()
                continuation.resume()
            }
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    guard let self, !finished, self.switchGeneration == generation else { return }
                    if message.hasPrefix("[\"EOSE\"") || message.hasPrefix("[\"CLOSED\"") {
                        // Let queued EVENTs drain through the sink first.
                        DispatchQueue.main.async { finish() }
                        return
                    }
                    self.processExternalMessage(message, forAccount: ownPubkey)
                }
                .store(in: &subs)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let req = ["REQ", subId, ["kinds": [1059], "#p": [ownPubkey], "limit": 1000]] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    } else if case .error = state {
                        finish()
                    }
                }
                .store(in: &subs)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { finish() }
            client.connect(url: url)
        }
    }

    /// Handles messages from external relay fetch (both NIP-17 and NIP-04)
    private func processExternalMessage(_ message: String, forAccount accountPubkey: String) {
        // Verify this message is still for the currently loaded account
        guard accountPubkey == loadedAccountPubkey else { return }

        guard let data = message.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let type = json[0] as? String else {
                return
            }

            if type == "EVENT",
               let eventData = json[safe: 2] as? [String: Any],
               let eventJSON = try? JSONSerialization.data(withJSONObject: eventData),
               let event = try? JSONDecoder().decode(NostrEvent.self, from: eventJSON) {
                // Unsigned or forged: neither show it nor store it locally.
                guard Self.isAuthentic(event) else { return }

                // Process the DM for display
                if event.kind == 1059 {
                    self.handleIncomingGiftWrap(event)
                } else if event.kind == 4 {
                    self.handleIncomingNIP04(event)
                }

                // Also inject the raw event into the local relay so it persists
                // across app restarts and syncs to other devices via the Go relay.
                self.injectExternalDmIntoLocalRelay(eventData, eventId: event.id, kind: event.kind)
            }
        } catch {
            #if DEBUG
            print("❌ Failed to process external message: \(error)")
            #endif
        }
    }
}

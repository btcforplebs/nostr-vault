import Foundation
import Combine

extension DMService {
    /// Fetch DMs from the user's known external relays (the Read relays, then
    /// the DM inbox) to catch any gift wraps not yet imported by the Go relay.
    func fetchFromExternalRelays() {
        let ownPubkey = loadedAccountPubkey
        guard !ownPubkey.isEmpty else { return }
        // A fetch is still running (each relay stays open up to 15 s). The
        // app's foreground ran this twice, 3 s apart: refresh(), then
        // syncOnForeground() before the first had stamped its time.
        guard externalClients.isEmpty else { return }
        backfillSentCopiesIfNeeded()

        let generation = self.switchGeneration

        // Your DM inbox relays first: that is where DMs to you (and your
        // sent copies from other devices) are published. The feed's read
        // relays used to come first, and a long feed list pushed the DM
        // relays past the cap.
        let ownDMRelays = (NostrService.shared.dmRelayLists[ownPubkey] ?? [])
            .filter { !NostrService.isLoopbackRelay($0) }
        // Your general (kind 10002) read relays: builds before the DM inbox
        // list sent your own copies there when that list happened to be
        // found first, so this is where those messages are.
        let ownReadRelays = (NostrService.shared.relayLists[ownPubkey] ?? [])
            .filter { !NostrService.isLoopbackRelay($0) }
        // Counterpart DM relays: messages to us are published there.
        let counterpartRelays = conversations.flatMap { NostrService.shared.dmRelayLists[$0.id] ?? [] }
        let ownGroups = [ownDMInboxRelays(), ownDMRelays, ConfigService.shared.config.readRelays, ownReadRelays]
        let ownRelayKeys = Set(ownGroups.joined().map(DMReadAuth.relayKey))
        let relays = DMReadAuth.fetchRelays(ownGroups + [counterpartRelays], cap: 15)

        #if DEBUG
        print("🌐 Fetching DMs from \(relays.count) external relays...")
        #endif

        for urlStr in relays {
            guard let url = URL(string: urlStr) else { continue }

            let client = WebSocketClient()
            client.isTemporary = true
            externalClients.append(client)
            let auth = readAuthLink(url: urlStr, account: ownPubkey,
                                    own: DMReadAuth.mayAuth(urlStr, own: ownRelayKeys))

            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self, weak client] message in
                    guard let self = self, let client else { return }
                    // Discard if account switched since this fetch started
                    DispatchQueue.main.async {
                        guard self.switchGeneration == generation else { return }
                        self.routeExternalFrame(message, auth: auth, client: client, forAccount: ownPubkey)
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
                        auth.connected = true
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
                        self.sendReadREQ(prefix: "ext-nip17-", filter: nip17Filter, client: client, auth: auth)

                        // NIP-04 legacy DMs (received)
                        var nip04FilterReceived: [String: Any] = [
                            "kinds": [4],
                            "#p": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 { nip04FilterReceived["since"] = since }
                        self.sendReadREQ(prefix: "ext-nip04-in-", filter: nip04FilterReceived, client: client, auth: auth)

                        // NIP-04 legacy DMs (sent)
                        var nip04FilterSent: [String: Any] = [
                            "kinds": [4],
                            "authors": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 { nip04FilterSent["since"] = since }
                        self.sendReadREQ(prefix: "ext-nip04-out-", filter: nip04FilterSent, client: client, auth: auth)

                        // Disconnect after timeout and update fetch timestamp.
                        // A relay that asked for AUTH gets 10 s more, once: a
                        // remote signer signs over its own relay, and the
                        // re-sent REQ still has to be answered.
                        func retire(after delay: TimeInterval) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                if auth.mayExtend() { retire(after: 10); return }
                                client.disconnect()
                                self?.externalClients.removeAll { $0 === client }
                                // Update timestamp and tear down injection clients when the last external client disconnects
                                if self?.externalClients.isEmpty == true {
                                    self?.lastExternalFetchTimestamp = Int64(Date().timeIntervalSince1970)
                                    self?.disconnectInjectionClients()
                                }
                            }
                        }
                        retire(after: 8)
                    }
                }
                .store(in: &cancellables)

            // A relay that never connects (or errors) used to stay in
            // externalClients forever: the cleanup above only runs after a
            // connect, so the list never emptied and the fetch timestamp
            // never advanced — every later fetch reused a days-old window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.externalClients.contains(where: { $0 === client }) else { return }
                // Connected late and reading (or AUTHing): its own timer above ends it.
                guard !auth.connected else { return }
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
        // v2: v1 ran before the read answered AUTH, so wraps kept only on
        // relays that hand them out after AUTH (damus, nostr.wine) were never
        // fetched. One more all-time catch-up picks them up.
        let key = "dm.sentCopyBackfill.v2.\(ownPubkey)"
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
            // Every relay here is your own (10002 + DM inbox).
            let auth = readAuthLink(url: url.absoluteString, account: ownPubkey, own: true)
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
                    guard let (type, _) = self.routeExternalFrame(message, auth: auth, client: client, forAccount: ownPubkey) else { return }
                    // A CLOSED being answered with AUTH isn't the end: the
                    // REQ goes again once the relay lets us in. Nor is one
                    // that came before the relay's challenge: the 12 s timer
                    // ends that wait, so the v2 pass isn't spent without AUTH.
                    if type == "EOSE" || (type == "CLOSED" && !auth.state.isAuthenticating
                                          && !auth.state.isAwaitingChallenge && !auth.resentRecently) {
                        // Let queued EVENTs drain through the sink first.
                        DispatchQueue.main.async { finish() }
                    }
                }
                .store(in: &subs)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        auth.connected = true
                        self.sendReadREQ(prefix: "bf-", filter: ["kinds": [1059], "#p": [ownPubkey], "limit": 1000], client: client, auth: auth)
                    } else if case .error = state {
                        finish()
                    }
                }
                .store(in: &subs)
            // 12 s, and 10 s more once when the relay asked for AUTH.
            func timeout(after delay: TimeInterval) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if auth.mayExtend() { timeout(after: 10) } else { finish() }
                }
            }
            timeout(after: 12)
            client.connect(url: url)
        }
    }

    /// Relays whose DM-read AUTH failed this app session ("account|url"):
    /// refused, closed again after AUTH, or the signer didn't sign. They are
    /// read without AUTH from then on, so a remote signer is asked at most
    /// once per relay per connection and never again after a failure.
    static var readAuthGivenUp = Set<String>()

    func readAuthLink(url: String, account: String, own: Bool) -> DMReadAuthLink {
        DMReadAuthLink(url: url, account: account,
                       mayAuth: own && !Self.readAuthGivenUp.contains("\(account)|\(url)"))
    }

    /// Sends a REQ and remembers it, so it can be sent again after AUTH.
    func sendReadREQ(prefix: String, filter: [String: Any], client: WebSocketClient, auth: DMReadAuthLink) {
        let subId = "\(prefix)\(UUID().uuidString.prefix(6))"
        let req = ["REQ", subId, filter] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else { return }
        auth.state.sent(subId: subId, req: str)
        client.send(text: str)
    }

    /// EVENTs go to the DM path; AUTH, CLOSED and OK to the read's NIP-42
    /// answer. Returns the frame's type (nil when it isn't one).
    @discardableResult
    func routeExternalFrame(_ message: String, auth: DMReadAuthLink, client: WebSocketClient, forAccount account: String) -> (String, [Any])? {
        if message.hasPrefix("[\"EVENT\"") {
            processExternalMessage(message, forAccount: account)
            return ("EVENT", [])
        }
        guard let (type, json) = RelayFrame.parse(message) else { return nil }
        if type == "EVENT" {
            processExternalMessage(message, forAccount: account)
            return (type, json)
        }
        guard account == loadedAccountPubkey else { return (type, json) }
        apply(auth.state.receive(type: type, json: json), auth: auth, client: client)
        return (type, json)
    }

    private func apply(_ step: DMReadAuth.Step, auth: DMReadAuthLink, client: WebSocketClient) {
        switch step {
        case .none:
            break
        case .sign(let challenge):
            let generation = switchGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                let signed = self.switchGeneration == generation
                    ? await self.signRelayAuth(url: auth.url, challenge: challenge, as: auth.account)
                    : nil
                guard let signed else {
                    self.apply(auth.state.signFailed(), auth: auth, client: client)
                    return
                }
                auth.state.authSent(id: signed.id)
                client.send(text: signed.message)
            }
        case .resend(let reqs):
            #if DEBUG
            print("🔐 DM read AUTH accepted by \(auth.url): asking again (\(reqs.count))")
            #endif
            auth.resentAt = Date()
            for req in reqs { client.send(text: req) }
        case .giveUp(let why):
            #if DEBUG
            print("🔐 DM read AUTH given up for \(auth.url): \(why)")
            #endif
            Self.readAuthGivenUp.insert("\(auth.account)|\(auth.url)")
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

/// One DM-reading connection's NIP-42 state, shared by its sink and timers.
@MainActor
final class DMReadAuthLink {
    let url: String
    let account: String
    var state: DMReadAuth
    var connected = false
    var resentAt: Date?
    private var extended = false

    init(url: String, account: String, mayAuth: Bool) {
        self.url = url
        self.account = account
        self.state = DMReadAuth(mayAuth: mayAuth)
    }

    var resentRecently: Bool { resentAt.map { Date().timeIntervalSince($0) < 8 } ?? false }

    /// True once, when an AUTH is under way or its re-sent REQ was just
    /// sent: the caller keeps the connection open a little longer.
    func mayExtend() -> Bool {
        guard !extended, state.isAuthenticating || resentRecently else { return false }
        extended = true
        return true
    }
}

import Foundation
import Combine

extension DMService {
    func fetchRecipientDMRelays(_ pubkey: String) async -> [String] {
        // Someone else's advertised 127.0.0.1 resolves to OUR machine, so
        // publishing there drops their DM into our own relay — the write
        // succeeds and the message is simply lost. Older builds advertised
        // exactly that, so these entries are out there and must be dropped.
        // Filtering can empty a list; falling through to the next source is
        // what keeps that from silently sending nowhere.
        func reachable(_ relays: [String]) -> [String] {
            relays.filter { !NostrService.isLoopbackRelay($0) }
        }

        // NIP-17: Check kind 10050 (DM relay preferences) first
        if let dmRelays = NostrService.shared.dmRelayLists[pubkey] {
            let usable = reachable(dmRelays)
            if !usable.isEmpty {
                #if DEBUG
                print("📋 Using NIP-17 DM relays for \(pubkey.prefix(8)): \(usable)")
                #endif
                return usable
            }
            if !dmRelays.isEmpty {
                #if DEBUG
                print("⚠️ \(pubkey.prefix(8)) advertises only loopback DM relays — falling back")
                #endif
            }
        }

        // No DM relay list known yet: fetch, and wait for it. A general
        // (kind 10002) list is only a fallback for someone who has published
        // no DM list, so it must not win just because it arrived first — the
        // two are fetched together and whichever landed first used to decide.
        NostrService.shared.fetchRelayList(for: pubkey)

        // Wait up to 4 seconds for the DM relay list to arrive
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

            if let dmRelays = NostrService.shared.dmRelayLists[pubkey] {
                let usable = reachable(dmRelays)
                if !usable.isEmpty {
                    #if DEBUG
                    print("📋 Fetched NIP-17 DM relays for \(pubkey.prefix(8)): \(usable)")
                    #endif
                    return usable
                }
            }
        }

        // Fallback to kind 10002 (general read relays)
        if let readRelays = NostrService.shared.relayLists[pubkey] {
            let usable = reachable(readRelays)
            if !usable.isEmpty {
                #if DEBUG
                print("📋 Using kind 10002 relay list for \(pubkey.prefix(8)): \(usable)")
                #endif
                return usable
            }
        }

        // Fallback: use common relays where most users have inbox
        let fallbackRelays = ConfigService.shared.config.writeRelays
        #if DEBUG
        print("⚠️ No relay list for \(pubkey.prefix(8)), using fallback relays")
        #endif
        return fallbackRelays
    }

    /// Publishes an event to the local /chat relay.
    /// Reuses the persistent inboxClient when connected (zero latency).
    /// Falls back to the injection client pattern (queues + sends on connect).
    func publishToInbox(_ event: NostrEvent) {
        let eventDict = eventToDict(event)

        // Fast path: reuse the already-connected persistent inbox client
        if let client = inboxClient, client.connectionState == .connected {
            sendEventToClient(client, eventDict)
            return
        }

        // Fallback: queue via injection client (sends on connect)
        injectViaChatClient(eventDict)
    }

    func eventToDict(_ event: NostrEvent) -> [String: Any] {
        return [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ]
    }

    /// Fire-and-forget publish to an external relay.
    /// Connects, sends EVENT, and disconnects after a short flush window.
    /// Does NOT block the caller — errors are logged but not propagated.
    /// This account's DM inbox list, minus loopback entries. For the owner
    /// that is the published list — the Haven inbox (Mac relay) first. Other
    /// accounts use the plain DM relays: the owner's Haven inbox only takes
    /// DMs addressed to the owner.
    func ownDMInboxRelays() -> [String] {
        let config = ConfigService.shared.config
        let ownerHex = Bech32.decode(config.ownerNpub)?.hexString ?? ""
        let list = loadedAccountPubkey == ownerHex ? config.dmInboxRelays : config.dmRelays
        return list.filter { !NostrService.isLoopbackRelay($0) }
    }

    /// Publishes to a relay that may require NIP-42 AUTH before it accepts a
    /// write. A Haven inbox (the Mac relay) does: it rejects the event with
    /// "auth-required" until the owner authenticates, and the plain
    /// fire-and-forget publish never noticed. Here an auth-required rejection
    /// is answered with AUTH — signed by the account that is sending, never
    /// the owner on another account's behalf, which would tie the two
    /// accounts together for the relay — and the event is sent once more. Relays that need no AUTH accept it on
    /// the first try. Logs the outcome; never blocks the caller.
    func publishAuthenticated(_ event: NostrEvent, url: String) {
        guard let urlObj = URL(string: url) else { return }
        let client = WebSocketClient()
        client.isTemporary = true
        let eventMsg: String? = {
            let msg = ["EVENT", eventToDict(event)] as [Any]
            guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        guard let eventMsg else { return }

        let sender = loadedAccountPubkey
        var challenge: String?
        var authSent = false
        var authEventId: String?
        var done = false
        var subs = Set<AnyCancellable>()
        func finish(_ ok: Bool, _ note: String) {
            guard !done else { return }
            done = true
            #if DEBUG
            print(ok ? "📤 DM wrap \(event.id.prefix(8)) accepted by \(url)" : "⚠️ DM wrap \(event.id.prefix(8)) not stored by \(url): \(note)")
            #endif
            client.disconnect()
            subs.removeAll()
        }

        client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self, !done,
                      let data = message.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = json.first as? String else { return }
                switch type {
                case "AUTH":
                    challenge = json[safe: 1] as? String
                case "OK":
                    guard let id = json[safe: 1] as? String else { return }
                    let accepted = (json[safe: 2] as? Bool) ?? false
                    let note = (json[safe: 3] as? String) ?? ""
                    // khatru handles each message on its own goroutine, so a
                    // retry sent right behind the AUTH can be judged before
                    // the AUTH lands. Resend only once the AUTH is accepted.
                    if let authId = authEventId, id == authId {
                        if accepted { client.send(text: eventMsg) } else { finish(false, "AUTH rejected: \(note)") }
                        return
                    }
                    guard id == event.id else { return }
                    if accepted || note.hasPrefix("duplicate") {
                        finish(true, note)
                    } else if note.hasPrefix("auth-required"), !authSent, let challenge {
                        authSent = true
                        Task { @MainActor in
                            // signEventAsync signs as the active account; if
                            // that changed since the send, don't prove the
                            // wrong identity.
                            guard NostrService.shared.activeHexPubkey == sender else {
                                finish(false, "account switched before AUTH")
                                return
                            }
                            let tags = [["relay", url], ["challenge", challenge]]
                            guard let auth = await NostrService.shared.signEventAsync(kind: 22242, content: "", tags: tags) else {
                                finish(false, "could not sign AUTH")
                                return
                            }
                            let msg = ["AUTH", self.eventToDict(auth)] as [Any]
                            if let data = try? JSONSerialization.data(withJSONObject: msg),
                               let str = String(data: data, encoding: .utf8) {
                                authEventId = auth.id
                                client.send(text: str)
                            }
                        }
                    } else {
                        finish(false, note)
                    }
                default:
                    break
                }
            }
            .store(in: &subs)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    client.send(text: eventMsg)
                } else if case .error = state {
                    finish(false, "connection failed")
                }
            }
            .store(in: &subs)

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            finish(false, "timed out")
        }
        client.connect(url: urlObj)
    }

    func fireAndForgetPublish(_ event: NostrEvent, url: String) {
        guard let urlObj = URL(string: url) else { return }

        let client = WebSocketClient()
        client.isTemporary = true
        let eventDict = eventToDict(event)

        let sub = client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    let msg = ["EVENT", eventDict] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: msg),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                    // Short flush window for TCP send buffer, then disconnect
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        client.disconnect()
                    }
                } else if case .error = state {
                    client.disconnect()
                }
            }
        self.cancellables.insert(sub)

        // Connect timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if client.connectionState != .connected {
                client.disconnect()
            }
        }

        client.connect(url: urlObj)
    }
}

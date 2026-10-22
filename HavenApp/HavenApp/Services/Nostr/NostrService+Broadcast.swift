import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// Posts an event to the local relay and broadcasts to configured relays
    /// - Parameter directBroadcast: false when the caller broadcasts the event
    ///   itself (ModePostPublisher does, to report each relay's answer).
    /// `onBroadcastOutcome`, when given, is called once on the main thread:
    /// `.accepted` as soon as one broadcast relay takes the event, `.refused`
    /// if none has after a few quiet retries. Without it, nothing changes.
    func postEvent(_ event: NostrEvent, directBroadcast: Bool = true,
                   onBroadcastOutcome: ((BroadcastTally.Outcome) -> Void)? = nil) {
        #if DEBUG
        print("NostrService: postEvent called – id=\(event.id.prefix(8)) kind=\(event.kind) sig=\(event.sig.prefix(8))")
        #endif
        // Note: the relay-activity red dot is driven solely by inbound events from
        // others (see RelayProcessManager), so self-authored posts never trigger it.

        // Update local state immediately for instant feedback
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.markSeen(event.id) {
                self.events.insert(event, at: 0)
                self.events.sort(by: { $0.created_at > $1.created_at })

                // Extract media URLs and add to noteMedia
                let urls = NoteTagging.contentMediaIsAuthors(kind: event.kind)
                    ? self.extractMediaURLs(from: event.content)
                    : []
                let items = urls.map { url in
                    let mime = Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime)
                }
                if !items.isEmpty {
                    self.noteMedia.append(contentsOf: items)
                }

                self.eventUpdateSubject.send()
            }
        }

        let eventDict: [String: Any] = [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ]

        let msg = ["EVENT", eventDict] as [Any]

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        // Cache raw event JSON immediately so rebroadcast + NIP-18 repost embedding
        // work without waiting for the event to echo back from the relay.
        if event.kind == 1 || event.kind == 6 || event.kind == 30023 || event.kind == NIP10Thread.commentKind || event.kind == NIP88Poll.kind {
            if let evData = try? JSONSerialization.data(withJSONObject: eventDict, options: []),
               let evJSON = String(data: evData, encoding: .utf8) {
                FeedService.shared.cacheRawEvent(id: event.id, json: evJSON)
            }
        }

        // 1. Post to local relay — reuse the feed's already-connected socket
        // (the nostr way: one connection, send EVENT through it, no new TLS handshake)
        let relayReady = RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting
        if relayReady {
            let localURLString = ConfigService.shared.config.nostrURL
            if FeedService.shared.sendToLocalRelay(str) {
                // Sent through existing feed connection
            } else if let existing = clients[localURLString], existing.connectionState == .connected {
                existing.send(text: str)
            } else if let localURL = URL(string: localURLString) {
                // Last resort: temporary client
                let localClient = WebSocketClient()
                localClient.isTemporary = true

                localClient.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        if state == .connected {
                            localClient.send(text: str)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                localClient.disconnect()
                            }
                        }
                    }
                    .store(in: &cancellables)

                localClient.connect(url: localURL)
                trackTemporaryClient(localClient)
            }
        } else {
            #if DEBUG
            print("NostrService: ⚠️ Local relay not ready — event \(event.id.prefix(8)) will reach network via direct blast only")
            #endif
        }

        #if os(iOS)
        // 1b. A copy for the owner's home vault (a kiosk phone on the mesh), if one is set.
        HomeVaultSender.shared.enqueue(eventDict: eventDict)
        // 1c. A copy for the owner's browser relay (a nostrvault.app page on the mesh), if one is set.
        BrowserRelaySender.shared.enqueue(eventDict: eventDict)
        #endif

        // 2. Smart Broadcast: Send to author's inbox relays if it's a reply or reaction
        if event.kind == 1 || event.kind == 6 || event.kind == 7 || event.kind == NIP10Thread.commentKind {
            // Find target author's pubkey from 'p' tags (skipping own pubkey)
            let targetPubkey = event.tags.first { $0.count >= 2 && $0[0] == "p" && $0[1] != activeHexPubkey }?[1]

            if let targetPubkey = targetPubkey, let targetRelays = relayLists[targetPubkey] {
                #if DEBUG
                print("NostrService: Smart broadcast event \(event.id.prefix(8)) to \(targetPubkey.prefix(8))'s inbox relays: \(targetRelays)")
                #endif

                let blastrRelays = ConfigService.shared.config.activeBlastrRelays
                for relayURLString in targetRelays {
                    // Skip relays already covered by the direct blast
                    if blastrRelays.contains(relayURLString) { continue }

                    guard let url = URL(string: relayURLString) else { continue }
                    let smartClient = WebSocketClient()
                    smartClient.isTemporary = true

                    smartClient.$connectionState
                        .receive(on: DispatchQueue.main)
                        .sink { state in
                            if state == .connected {
                                smartClient.send(text: str)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    smartClient.disconnect()
                                }
                            }
                        }
                        .store(in: &cancellables)

                    smartClient.connect(url: url)
                    trackTemporaryClient(smartClient)
                }
            } else if let targetPubkey = targetPubkey {
                // We don't have their relays yet, fetch for next time
                fetchRelayList(for: targetPubkey)
            }
        }

        // 3. Direct broadcast: every event goes to the blastr relays from here
        //    too, not only through the local relay. See
        //    RelayConfiguration.directBroadcastRelays for why.
        if directBroadcast {
            // The same list the relay blasts to, so a Mac reached over the
            // mesh is asked too and its OK confirms the post.
            #if os(iOS)
            let mesh = RelayConfiguration.macMeshRelay
            #else
            let mesh: RelayConfiguration.MacMeshRelay? = nil
            #endif
            let relays = RelayConfiguration.directBroadcastRelays(
                kind: event.kind,
                tags: event.tags,
                blastrRelays: RelayConfiguration.blastrRelays(config: ConfigService.shared.config, mesh: mesh),
                ownerWriteRelays: outboxRelays[event.pubkey] ?? []
            )
            if let onBroadcastOutcome {
                broadcastConfirmed(eventDict, to: relays, attemptsLeft: 3, completion: onBroadcastOutcome)
            } else {
                broadcastRawEvent(eventDict, to: relays)
            }
        } else {
            onBroadcastOutcome?(.refused)
        }

    }

    /// Sends to `relays` and reports a single outcome. When every relay
    /// refuses or times out it tries again, a little later each time, before
    /// giving up: a slow relay shouldn't read as a failed post.
    private func broadcastConfirmed(_ eventDict: [String: Any], to relays: [String], attemptsLeft: Int,
                                    completion: @escaping (BroadcastTally.Outcome) -> Void) {
        var tally = BroadcastTally(relayCount: relays.count)
        if tally.outcome != nil {
            completion(.refused)
            return
        }
        broadcastRawEvent(eventDict, to: relays) { [weak self] relay, success, message in
            switch tally.record(relay: relay, success: success, message: message) {
            case .accepted?:
                completion(.accepted)
            case .refused? where attemptsLeft > 1:
                let delay: TimeInterval = attemptsLeft > 2 ? 3 : 8
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.broadcastConfirmed(eventDict, to: relays, attemptsLeft: attemptsLeft - 1, completion: completion)
                }
            case .refused?:
                completion(.refused)
            case nil:
                break
            }
        }
    }

    /// Broadcasts a raw signed event dict (including sig) to configured Blastr relays.
    /// Use this to re-broadcast an existing event without re-signing it.
    /// If `onRelayResult` is provided, it's called for each relay with (relayURL, success, message).
    /// `extraRelays` are sent to as well, e.g. diVine's relay for a diVine.
    func broadcastRawEvent(_ eventDict: [String: Any], extraRelays: [String] = [], onRelayResult: ((String, Bool, String) -> Void)? = nil) {
        var relays = ConfigService.shared.config.writeRelays
        for extra in extraRelays where !relays.contains(extra) {
            relays.append(extra)
        }
        broadcastRawEvent(eventDict, to: relays, onRelayResult: onRelayResult)
    }

    /// Broadcasts a raw signed event dict to exactly `relays`, no defaults added.
    func broadcastRawEvent(_ eventDict: [String: Any], to relays: [String], onRelayResult: ((String, Bool, String) -> Void)? = nil) {
        let msg = ["EVENT", eventDict] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        for urlStr in relays {
            guard let url = URL(string: urlStr) else { continue }
            let client = WebSocketClient()
            client.isTemporary = true
            var hasReported = false

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard !hasReported,
                          let msgData = message.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: msgData) as? [Any],
                          json.count >= 3,
                          let type = json[0] as? String,
                          type == "OK" else { return }
                    hasReported = true
                    let success = json[2] as? Bool ?? false
                    let relayMsg = json.count >= 4 ? (json[3] as? String ?? "") : ""
                    onRelayResult?(urlStr, success, relayMsg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        client.send(text: str)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            guard !hasReported else { return }
                            hasReported = true
                            onRelayResult?(urlStr, false, "timeout")
                            client.disconnect()
                        }
                    } else if state == .error && !hasReported {
                        hasReported = true
                        onRelayResult?(urlStr, false, "connection failed")
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            trackTemporaryClient(client)
        }
    }
}

import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Insert a raw event JSON string into the cache (for own posts / rebroadcast).
    /// Every write to `rawEventCache` must go through here: a writer that
    /// bypasses `rawEventCacheOrder` lets the dict outgrow the order array,
    /// and eviction's removeFirst then traps (the recurring post-time crash).
    /// Keeps a copy of a post you liked on your own relay. Your relay's root
    /// only stores your events and its inbox only events that tag you, so a
    /// liked post lived nowhere local: Relay > Likes > Given then had to find
    /// it on outside relays, which on 2026-10-05 returned 47 of 293. The /feed
    /// store takes any note; it keeps the feed window (7 days, plus a day).
    func keepLikedNoteLocally(id: String) {
        guard let json = rawEventCache[id], let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["id"] as? String == id else { return }
        NostrService.shared.broadcastRawEvent(dict, to: [ConfigService.shared.config.nostrURL + "/feed"])
    }

    func cacheRawEvent(id: String, json: String) {
        if rawEventCache[id] == nil {
            rawEventCacheOrder.append(id)
        }
        rawEventCache[id] = json
        if rawEventCache.count > Self.maxRawEventCacheSize {
            // Clamp so a residual desync degrades to partial eviction
            // instead of trapping in removeFirst.
            let overflow = min(rawEventCache.count - Self.maxRawEventCacheSize,
                               rawEventCacheOrder.count)
            let keysToRemove = rawEventCacheOrder.prefix(overflow)
            for key in keysToRemove { rawEventCache.removeValue(forKey: key) }
            rawEventCacheOrder.removeFirst(overflow)
        }
        if rawEventCache.count > Self.maxRawEventCacheSize {
            // Still over cap: the dict holds keys the order array never
            // tracked. Drop untracked keys until back under the cap.
            let tracked = Set(rawEventCacheOrder)
            for key in rawEventCache.keys.filter({ !tracked.contains($0) }) {
                rawEventCache.removeValue(forKey: key)
                if rawEventCache.count <= Self.maxRawEventCacheSize { break }
            }
        }
    }

    /// Send a raw Nostr message through the already-connected local relay client.
    /// Returns true if sent, false if no connected local client exists.
    func sendToLocalRelay(_ text: String) -> Bool {
        guard let key = localRelayURL?.absoluteString,
              let client = feedClients[key],
              client.connectionState == .connected else {
            return false
        }
        client.send(text: text)
        return true
    }

    // MARK: - Local Relay Injection

    /// Injects an external event into the local relay. Safe to call from any
    /// context — hops to MainActor internally. Filters to feed-relevant kinds
    /// (`FeedNote.timelineKinds`, 7, 9735) and deduplicates via the shared injectedEventIds set.
    nonisolated func injectExternalEvent(_ eventDict: [String: Any], eventId: String) {
        guard let kind = eventDict["kind"] as? Int,
              (FeedNote.timelineKinds + [7, 9735]).contains(kind) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.injectIntoLocalRelay(eventDict, eventId: eventId)
        }
    }

    /// Parses an external relay message and injects the event into the local relay.
    /// Called on `processingQueue` — must be thread-safe.
    nonisolated func handleExternalEventInjection(_ msg: String) {
        // The WOT globe's live arrivals (Global included) never go in your relay.
        if GlobeArcs.isGlobeMessage(msg) { return }
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 3,
              let type = json[0] as? String, type == "EVENT",
              let ev = json[2] as? [String: Any],
              let eventId = ev["id"] as? String else { return }

        // Only inject feed-relevant event kinds (notes, reactions, reposts, zaps)
        guard let kind = ev["kind"] as? Int,
              (FeedNote.timelineKinds + [7, 9735]).contains(kind) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.injectIntoLocalRelay(ev, eventId: eventId)
        }
    }

    /// Writes an event to the local relay. Routes owner/whitelisted events to outbox,
    /// external events to /inbox (which has no blast hook, preventing feedback loops).
    private func injectIntoLocalRelay(_ eventDict: [String: Any], eventId: String) {
        // Dedup: skip events already injected this session
        guard !injectedEventIds.contains(eventId) else { return }
        injectedEventIds.insert(eventId)
        if injectedEventIds.count > maxInjectedIds {
            injectedEventIds.removeAll(keepingCapacity: true)
            injectedEventIds.insert(eventId)
        }

        let config = ConfigService.shared.config
        let ownerHex = Bech32.decode(config.ownerNpub)?.hexString ?? ""
        let whitelisted = ConfigService.shared.whitelistedHexPubkeys

        let pubkey = eventDict["pubkey"] as? String ?? ""
        let isTrackedAuthor = pubkey == ownerHex || whitelisted.contains(pubkey)

        let msg: [Any] = ["EVENT", eventDict]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        // Route to the appropriate injection client
        if isTrackedAuthor {
            sendToOutboxInjection(str)
        } else {
            sendToInboxInjection(str)
        }

        notifyInjectionComplete()
    }

    /// Sends a message to the outbox injection client, queuing if not yet connected.
    private func sendToOutboxInjection(_ str: String) {
        if let client = outboxInjectionClient, client.connectionState == .connected {
            client.send(text: str)
            return
        }

        pendingOutboxMessages.append(str)

        // Already connecting, just queue
        if outboxInjectionClient != nil { return }

        guard let url = URL(string: ConfigService.shared.config.nostrURL) else { return }

        let client = WebSocketClient()
        client.isTemporary = false
        outboxInjectionClient = client
        isInjecting = true

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, state == .connected else { return }
                for pending in self.pendingOutboxMessages {
                    client.send(text: pending)
                }
                self.pendingOutboxMessages.removeAll()
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    /// Sends a message to the inbox injection client, queuing if not yet connected.
    private func sendToInboxInjection(_ str: String) {
        if let client = inboxInjectionClient, client.connectionState == .connected {
            client.send(text: str)
            return
        }

        pendingInboxMessages.append(str)

        // Already connecting, just queue
        if inboxInjectionClient != nil { return }

        guard let url = URL(string: ConfigService.shared.config.nostrURL + "/inbox") else { return }

        let client = WebSocketClient()
        client.isTemporary = false
        inboxInjectionClient = client
        isInjecting = true

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, state == .connected else { return }
                for pending in self.pendingInboxMessages {
                    client.send(text: pending)
                }
                self.pendingInboxMessages.removeAll()
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    /// Disconnects injection clients (called from pauseFeed).
    func disconnectInjectionClients() {
        outboxInjectionClient?.disconnect()
        outboxInjectionClient = nil
        inboxInjectionClient?.disconnect()
        inboxInjectionClient = nil
        pendingOutboxMessages.removeAll()
        pendingInboxMessages.removeAll()
        isInjecting = false
    }

    /// Posts `.feedInjectionComplete` at most once per 30 seconds.
    private func notifyInjectionComplete() {
        let now = Date()
        guard now.timeIntervalSince(lastInjectionNotification) > 30 else { return }
        lastInjectionNotification = now
        NotificationCenter.default.post(name: .feedInjectionComplete, object: nil)
    }
}

import Foundation
import Combine
import SwiftUI

extension FeedService {
    static func relayStateKey(_ url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// The socket state of one configured relay, or nil when the feed is not
    /// using it right now (paused, or a feed served by another service).
    func relayState(for url: String) -> WebSocketClient.ConnectionState? {
        relayStates[Self.relayStateKey(url)]
    }

    func watchRelayState(_ client: WebSocketClient, key: String) {
        let stateKey = Self.relayStateKey(key)
        relayStateSinks[key] = client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self, let client, self.feedClients[key] === client else { return }
                self.relayStates[stateKey] = state
            }
    }

    var localRelayURL: URL? {
        // Only include the local relay when it is confirmed running.
        // During boot (WoT initialization, ~3 min) the HTTP server may be
        // listening but not fully ready, causing WebSocket failures.
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else { return nil }
        return URL(string: ConfigService.shared.config.nostrURL)
    }

    /// Local inbox relay — stores zaps, reactions, and mentions imported from seed relays.
    var localInboxURL: URL? {
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else { return nil }
        return URL(string: ConfigService.shared.config.nostrURL + "/inbox")
    }

    /// Local feed-cache relay — follows' recent notes kept in sync by the
    /// embedded relay (negentropy against the feed relays). Serves the feed
    /// window from disk instantly on cold start and for pagination.
    var localFeedURL: URL? {
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else { return nil }
        return URL(string: ConfigService.shared.config.nostrURL + "/feed")
    }

    /// Public relays used to supplement the local relay: the read relays.
    var externalRelayURLs: [URL] {
        ConfigService.shared.config.readRelays.compactMap { URL(string: $0) }
    }

    /// Recomputes `outboxPlan` from the follow set and the NIP-65 lists known
    /// so far, and asks for the lists still missing — the plan grows as they
    /// arrive, through the next reconcile.
    func refreshOutboxPlan() {
        guard isFollowSetMode || (feedMode == .media && mediaFeedMode == .following),
              !followedPubkeys.isEmpty else {
            outboxPlan = [:]
            outboxPlanInputs = nil
            return
        }
        let inputs = FeedOutboxPlan.Inputs(
            follows: followedPubkeys,
            writeRelays: NostrService.shared.outboxRelays,
            feedRelays: externalRelayURLs.map(\.absoluteString),
            unreachableRelays: downRelayKeys
        )
        // Every reconcile lands here (each load round, older page and relay
        // drop), mostly with nothing changed, and the plan is built on the
        // main thread while the feed scrolls.
        guard inputs != outboxPlanInputs else { return }
        outboxPlanInputs = inputs
        requestRelayLists(for: Set(followedPubkeys))
        outboxPlan = FeedOutboxPlan.plan(inputs)
    }

    /// Every relay the feed subscribes to: the local relay, its inbox and feed
    /// cache, the feed relays, then the follows' own relays (`outboxPlan`).
    func feedRelayURLs() -> [URL] {
        var urls: [URL] = []
        if let local = localRelayURL { urls.append(local) }
        if let inbox = localInboxURL { urls.append(inbox) }
        if let feed = localFeedURL { urls.append(feed) }
        urls.append(contentsOf: externalRelayURLs)
        let have = Set(urls.map(\.absoluteString))
        for raw in outboxPlan.keys.sorted() where !have.contains(raw) {
            if let url = URL(string: raw) { urls.append(url) }
        }
        return urls
    }

    /// The follows to ask a given relay for: an outbox relay is asked only for
    /// the follows it was picked for, every other relay for all of them.
    func followAuthors(forRelayKey key: String) -> [String] {
        // Older-page clients are keyed `page-<url>`.
        let url = key.hasPrefix("page-") ? String(key.dropFirst(5)) : key
        return outboxPlan[url] ?? followedPubkeys
    }

    /// Used for de-duping relay URLs across the floor + outbox set.
    static func normalizeRelayKey(_ urlStr: String) -> String? {
        FeedFilterEngine.normalizeRelayKey(urlStr)
    }
}

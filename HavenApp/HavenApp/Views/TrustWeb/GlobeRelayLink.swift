import Foundation
import Combine

/// One of the globe's REQs on one relay, riding the feed's open connection
/// to it: the feed already holds one to each of your read relays, so the
/// globe opens no connections of its own while the feed's is up (Logen,
/// 10/15). Its subscription ids start `arcs-`, which the feed skips, and
/// closing it CLOSEs only those. A reconnect, or the feed swapping in a new
/// connection, sends it again, asking from that moment. The feed's sockets
/// don't reconnect themselves and a relay that fails three times is given
/// up on, so when the feed's connection is gone past a short wait the globe
/// opens one of its own, closed with it, and goes back to the feed's when
/// that is up again.
@MainActor
final class GlobeRelayLink {
    let url: URL
    private let filters: [[String: Any]]
    private let subId: String
    /// The REQ messages last sent, already split under the relay's size cap.
    private(set) var requests: [String]
    /// This link's own sub ids: it reads only their answers.
    private let ids: Set<String>
    private let onEvent: ([String: Any]) -> Void
    private var client: WebSocketClient?
    /// The globe opened `client` itself: it disconnects it when done.
    private var owned = false
    /// Rode the feed's connection once: while the feed reconnects, wait
    /// `feedGrace` for it rather than open one of our own.
    private var everShared = false
    /// When the feed's connection was last seen gone.
    private var feedLostAt: Date?
    /// When our own connection last tried to connect.
    private var ownTriedAt: Date = .distantPast
    private var sinks: Set<AnyCancellable> = []
    /// Notices the feed swapping its connection, which it does on a reconnect.
    private var recheck: Timer?

    /// Past the feed's own retry (8 s after an error).
    private static let feedGrace: TimeInterval = 10
    /// How often our own dropped connection tries again.
    private static let ownRetry: TimeInterval = 5

    init(url: URL, filters: [[String: Any]], onEvent: @escaping ([String: Any]) -> Void) {
        self.url = url
        self.filters = filters
        self.onEvent = onEvent
        subId = GlobeArcs.subscriptionPrefix + UUID().uuidString.prefix(8)
        requests = GlobeArcs.requests(filters, subId: subId)
        ids = GlobeArcs.subscriptions(of: requests)
        attach()
        recheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        }
    }

    /// CLOSEs the globe's subscriptions; the feed's connection stays open.
    func close() {
        recheck?.invalidate()
        recheck = nil
        detach()
    }

    /// The feed's connection to this relay, if it is open or opening. One
    /// that errored stays in the feed's list until the feed retries, and
    /// for good once it gives up on the relay: riding it hears nothing.
    private var feedClient: WebSocketClient? {
        guard let shared = FeedService.shared.feedClients[url.absoluteString],
              shared.connectionState == .connected || shared.connectionState == .connecting else { return nil }
        return shared
    }

    private func attach() {
        let shared = feedClient
        let now = Date()
        feedLostAt = shared == nil ? feedLostAt ?? now : nil
        if let client {
            if owned, shared == nil {
                // Our own, while the feed has none: try again if it dropped.
                if client.connectionState == .error || client.connectionState == .disconnected,
                   now.timeIntervalSince(ownTriedAt) >= Self.ownRetry {
                    ownTriedAt = now
                    client.connect(url: url)
                }
                return
            }
            // Still on the feed's current connection: nothing to do.
            if !owned, client === shared { return }
            detach()
        }
        if let shared {
            client = shared
            owned = false
            everShared = true
        } else if everShared, let lost = feedLostAt, now.timeIntervalSince(lost) < Self.feedGrace {
            return
        } else {
            let own = WebSocketClient()
            own.isTemporary = true
            ownTriedAt = now
            own.connect(url: url)
            client = own
            owned = true
        }
        guard let client else { return }
        // WebSocketClient delivers on the main thread. The feed's own
        // messages go past here too: only this link's are read.
        client.messageSubject
            .sink { [weak self] message in
                guard let self, let event = GlobeArcs.event(in: message, ids: self.ids) else { return }
                self.onEvent(event)
            }
            .store(in: &sinks)
        // Sent each time it connects: on first open and on every reconnect,
        // asking from now so nothing missed flies late.
        // Hop to the next turn: @Published fires before the state is stored.
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .filter { $0 == .connected }
            .sink { [weak self, weak client] _ in
                guard let self, let client else { return }
                let since = Int(Date().timeIntervalSince1970)
                self.requests = GlobeArcs.requests(GlobeArcs.filters(self.filters, since: since), subId: self.subId)
                for text in self.requests { client.send(text: text) }
            }
            .store(in: &sinks)
    }

    private func detach() {
        sinks.removeAll()
        guard let client else { return }
        if owned {
            client.disconnect()
        } else if client.connectionState == .connected {
            for text in GlobeArcs.closes(for: requests) { client.send(text: text) }
        }
        self.client = nil
        owned = false
    }
}

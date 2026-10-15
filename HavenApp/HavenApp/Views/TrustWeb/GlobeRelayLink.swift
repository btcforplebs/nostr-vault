import Foundation
import Combine

/// One of the globe's REQs on one relay, riding the feed's open connection
/// to it: the feed already holds one to each of your read relays, so the
/// globe opens none of its own (Logen, 10/15). Its subscription ids start
/// `arcs-`, which the feed skips, and closing it CLOSEs only those. A
/// reconnect, or the feed swapping in a new connection, sends it again.
/// Only a relay the feed has held no connection to since the globe opened
/// gets one of the globe's own, closed with it.
@MainActor
final class GlobeRelayLink {
    let url: URL
    /// The REQ messages, already split under the relay's size cap.
    let requests: [String]
    private let onEvent: ([String: Any]) -> Void
    private var client: WebSocketClient?
    /// The globe opened `client` itself: it disconnects it when done.
    private var owned = false
    /// Rode the feed's connection once: while the feed reconnects, wait for
    /// it rather than open one of our own.
    private var everShared = false
    private var sinks: Set<AnyCancellable> = []
    /// Notices the feed swapping its connection, which it does on a reconnect.
    private var recheck: Timer?

    init(url: URL, filters: [[String: Any]], onEvent: @escaping ([String: Any]) -> Void) {
        self.url = url
        self.onEvent = onEvent
        requests = GlobeArcs.requests(filters, subId: GlobeArcs.subscriptionPrefix + UUID().uuidString.prefix(8))
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

    /// The feed's connection to this relay, if it has one: open, or opening.
    private var feedClient: WebSocketClient? {
        FeedService.shared.feedClients[url.absoluteString]
    }

    private func attach() {
        let shared = feedClient
        if let client {
            // Still on the feed's current connection, or on our own while the
            // feed has none: nothing to do.
            if owned ? shared == nil : client === shared { return }
            detach()
        }
        if let shared {
            client = shared
            owned = false
            everShared = true
        } else if everShared {
            return
        } else {
            let own = WebSocketClient()
            own.isTemporary = true
            own.connect(url: url)
            client = own
            owned = true
        }
        guard let client else { return }
        // WebSocketClient delivers on the main thread. The feed's own
        // messages go past here too: only the globe's are read.
        client.messageSubject
            .sink { [weak self] message in
                guard message.hasPrefix("[\"EVENT\""), GlobeArcs.isGlobeMessage(message),
                      let data = message.data(using: .utf8),
                      let array = try? JSONSerialization.jsonObject(with: data) as? [Any], array.count >= 3,
                      let event = array[2] as? [String: Any] else { return }
                self?.onEvent(event)
            }
            .store(in: &sinks)
        // Sent each time it connects: on first open and on every reconnect.
        // Hop to the next turn: @Published fires before the state is stored.
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .filter { $0 == .connected }
            .sink { [weak self, weak client] _ in
                guard let self, let client else { return }
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

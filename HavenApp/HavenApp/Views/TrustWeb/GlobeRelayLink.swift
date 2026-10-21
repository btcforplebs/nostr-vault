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
/// uses one of its own (`GlobeOwnSockets`, one per relay however many links
/// ask, retried with a growing wait), and goes back to the feed's when that
/// is up again. Nothing polls: a link wakes when its connection drops or a
/// wait it set runs out (Logen's phone ran hot, 10/20).
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
    private var sinks: Set<AnyCancellable> = []
    /// The one wait this link has set: the feed's grace, the own
    /// connection's next try, or a look for the feed again.
    private var check: Timer?
    private var closed = false

    /// Past the feed's own retry (8 s after an error).
    private static let feedGrace: TimeInterval = 10
    /// While on our own connection, how often to look for the feed's again.
    private static let feedLook: TimeInterval = 60

    init(url: URL, filters: [[String: Any]], onEvent: @escaping ([String: Any]) -> Void) {
        self.url = url
        self.filters = filters
        self.onEvent = onEvent
        subId = GlobeArcs.subscriptionPrefix + UUID().uuidString.prefix(8)
        requests = GlobeArcs.requests(filters, subId: subId)
        ids = GlobeArcs.subscriptions(of: requests)
        attach()
    }

    /// CLOSEs the globe's subscriptions; the feed's connection stays open.
    func close() {
        closed = true
        check?.invalidate()
        check = nil
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

    /// Looks again in `seconds`, replacing any wait already set.
    private func later(_ seconds: TimeInterval) {
        check?.invalidate()
        check = Timer.scheduledTimer(withTimeInterval: max(0.5, seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        }
    }

    private func attach() {
        check?.invalidate()
        check = nil
        guard !closed else { return }
        let shared = feedClient
        let now = Date()
        feedLostAt = shared == nil ? feedLostAt ?? now : nil
        if let client {
            if owned, shared == nil {
                // Our own, while the feed has none: try again when its wait is up.
                later(GlobeOwnSockets.retry(url, now: now) ?? Self.feedLook)
                return
            }
            // Still on the feed's current connection: its drop wakes us.
            if !owned, client === shared { return }
            detach()
        }
        if let shared {
            client = shared
            owned = false
            everShared = true
        } else if everShared, let lost = feedLostAt, now.timeIntervalSince(lost) < Self.feedGrace {
            later(Self.feedGrace - now.timeIntervalSince(lost))
            return
        } else {
            client = GlobeOwnSockets.borrow(url)
            owned = true
            later(GlobeOwnSockets.retry(url, now: now) ?? Self.feedLook)
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
        // asking from now so nothing missed flies late. A drop looks again:
        // for the feed's, or our own's next try.
        // Hop to the next turn: @Published fires before the state is stored.
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self, let client else { return }
                switch state {
                case .connected:
                    let since = Int(Date().timeIntervalSince1970)
                    self.requests = GlobeArcs.requests(GlobeArcs.filters(self.filters, since: since), subId: self.subId)
                    for text in self.requests { client.send(text: text) }
                case .error, .disconnected:
                    self.attach()
                default:
                    break
                }
            }
            .store(in: &sinks)
    }

    private func detach() {
        sinks.removeAll()
        guard let client else { return }
        if client.connectionState == .connected {
            for text in GlobeArcs.closes(for: requests) { client.send(text: text) }
        }
        if owned { GlobeOwnSockets.giveBack(url) }
        self.client = nil
        owned = false
    }
}

/// The globe's own connections: one per relay however many of its links
/// need it (the to-you and the wider REQ used to open one each), shut when
/// the last lets go, and a dropped one tried again after a growing wait
/// (`GlobeArcs.ownRetryWait`) rather than every 5 s for good.
@MainActor
enum GlobeOwnSockets {
    private final class Entry {
        let client = WebSocketClient()
        var users = 0
        /// Tries since it was last connected.
        var attempts = 0
        var nextTry: Date = .distantPast
        var watch: AnyCancellable?
    }

    private static var entries: [URL: Entry] = [:]

    static func borrow(_ url: URL) -> WebSocketClient {
        let entry: Entry
        if let existing = entries[url] {
            entry = existing
        } else {
            entry = Entry()
            entry.client.isTemporary = true
            entry.watch = entry.client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak entry] state in
                    if state == .connected { entry?.attempts = 0 }
                }
            entries[url] = entry
        }
        entry.users += 1
        return entry.client
    }

    static func giveBack(_ url: URL) {
        guard let entry = entries[url] else { return }
        entry.users -= 1
        guard entry.users <= 0 else { return }
        entry.watch = nil
        entry.client.disconnect()
        entries[url] = nil
    }

    /// Connects a dropped connection if its wait is up. Returns how long
    /// until it may try next, or nil while it is open or opening.
    static func retry(_ url: URL, now: Date = Date()) -> TimeInterval? {
        guard let entry = entries[url] else { return nil }
        let state = entry.client.connectionState
        guard state == .error || state == .disconnected else { return nil }
        if now >= entry.nextTry {
            entry.attempts += 1
            entry.nextTry = now.addingTimeInterval(GlobeArcs.ownRetryWait(attempts: entry.attempts))
            entry.client.connect(url: url)
        }
        return entry.nextTry.timeIntervalSince(now)
    }
}

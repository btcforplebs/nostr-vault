import SwiftUI
import Combine

/// The Live now panel's streams (`LiveNow`): who you follow that is live
/// right now. Asks the read relays and zap.stream's (`LiveFeedService
/// .relayURLs`) by author and by `p` tag, as the Live tab's Following does,
/// then again every `LiveNow.refreshEvery` while the panel is on screen.
/// Nothing is saved: a stream only matters while it runs. Kept by
/// `SpaceColumn`, so a collapsed panel still shows how many are live.
@MainActor
final class LiveNowModel: ObservableObject {
    @Published private(set) var streams: [LiveStream] = []
    /// A first answer is in (or the ask timed out), so an empty list means nobody is live.
    @Published private(set) var loaded = false

    private var owner = ""
    private var events: [LiveStatusBook.Event] = []
    private var clients: [WebSocketClient] = []
    private var subscriptions: [AnyCancellable] = []
    private var timeout: DispatchWorkItem?
    private var timer: Timer?
    private var generation = 0

    /// Relays cap filter sizes; a long follow list is asked in parts.
    private static let maxPerFilter = 150
    private static let askTimeout: TimeInterval = 10

    func attach(_ hex: String) {
        guard hex != owner else { return }
        owner = hex
        streams = []
        loaded = false
        stop()
    }

    /// The panel is on screen: ask now and keep asking.
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: LiveNow.refreshEvery, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closeAsk()
    }

    func refresh() {
        closeAsk()
        generation += 1
        let gen = generation
        let follows = FeedService.shared.followedPubkeys
        guard !follows.isEmpty else {
            streams = []
            loaded = FeedService.shared.followListIsKnown
            return
        }
        events = []
        var filters: [[String: Any]] = []
        for start in stride(from: 0, to: follows.count, by: Self.maxPerFilter) {
            let chunk = Array(follows[start..<min(start + Self.maxPerFilter, follows.count)])
            filters.append(["kinds": [30311], "authors": chunk, "limit": 100])
            filters.append(["kinds": [30311], "#p": chunk, "limit": 100])
        }
        let message: [Any] = ["REQ", "livenow-\(UUID().uuidString.prefix(8))"] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let req = String(data: data, encoding: .utf8) else { return }
        let followSet = Set(follows)
        // A first look draws as answers come in; a later one swaps the list
        // once, at the end, so rows don't drop and come back while relays
        // answer one by one.
        let first = !loaded
        for url in LiveFeedService.relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            subscriptions.append(client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] text in self?.handle(text, gen: gen, first: first, follows: followSet) })
            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { client.send(text: req) }
            clients.append(client)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.loaded = true
            self.publish(follows: followSet)
            self.closeAsk()
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.askTimeout, execute: work)
    }

    private func closeAsk() {
        timeout?.cancel()
        timeout = nil
        subscriptions.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
    }

    private func handle(_ message: String, gen: Int, first: Bool, follows: Set<String>) {
        guard gen == generation,
              let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }
        if type == "EOSE" {
            if first { loaded = true; publish(follows: follows) }
            return
        }
        guard type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              event["kind"] as? Int == 30311,
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let tags = event["tags"] as? [[String]] else { return }
        events.append(.init(id: id, pubkey: pubkey, createdAt: createdAt, tags: tags))
        if first && loaded { publish(follows: follows) }
    }

    private func publish(follows: Set<String>) {
        let picked = LiveNow.pick(events, follows: follows,
                                  blocked: ConfigService.shared.activeAccountBlockedHexPubkeys,
                                  now: Int64(Date().timeIntervalSince1970))
        let next = picked.compactMap { LiveStream(id: $0.id, pubkey: $0.pubkey, createdAt: $0.createdAt, tags: $0.tags) }
        if next != streams { streams = next }
        NostrService.shared.fetchMissingProfiles(for: next.map(\.hostPubkey))
    }
}

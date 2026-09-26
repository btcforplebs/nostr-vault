import Foundation
import Combine

/// Live streams feed (NIP-53, kind 30311).
///
/// Nothing here is cached to the device's own relay, deliberately: a stream is
/// only interesting while it is running, and a saved one is a gravestone. That
/// is not a hypothetical — of 632 unique stream events pulled from nos.lol,
/// relay.primal.net and relay.zap.stream on 2026-09-05, 478 were already ended
/// and only 26 were live with a URL anything could play.
@MainActor
final class LiveFeedService: ObservableObject {
    static let shared = LiveFeedService()

    /// Streams that are live and playable, newest first.
    @Published private(set) var streams: [LiveStream] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var followSetIsEmpty = false
    /// Following by default. Live video is unmoderated third-party content, so
    /// the global set is opt-in behind the sensitive-content warning.
    @Published private(set) var scope: RecipeScope = .following

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var collected: [String: LiveStream] = [:]
    private var loadTimeout: Timer?

    private init() {}

    func setScope(_ newScope: RecipeScope) {
        guard newScope != scope else { return }
        scope = newScope
        streams = []
        collected.removeAll()
        refresh()
    }

    /// Live streams are the one feed where stale is actively wrong — a stream
    /// that ended two minutes ago still says `live` in memory. Always refetch.
    func loadIfNeeded() {
        guard !isLoading else { return }
        refresh()
    }

    func refresh() {
        disconnect()
        collected.removeAll()
        loadFailed = false
        followSetIsEmpty = false
        isLoading = true

        var filters: [[String: Any]] = [["kinds": [30311], "limit": 300]]
        var follows: Set<String>?
        if scope == .following {
            let followed = FeedService.shared.followedPubkeys
            guard !followed.isEmpty else {
                isLoading = false
                followSetIsEmpty = true
                return
            }
            // Asked twice: by author, and by `p` tag for streams a service
            // publishes on the host's behalf. The `p` half also returns
            // streams a followed pubkey is only a guest on, which `handle`
            // drops.
            filters = [
                ["kinds": [30311], "authors": followed, "limit": 300],
                ["kinds": [30311], "#p": followed, "limit": 300],
            ]
            follows = Set(followed)
        }

        let relayURLs = Self.relayURLs
        guard !relayURLs.isEmpty else {
            isLoading = false
            loadFailed = true
            return
        }

        let subId = "live-\(UUID().uuidString.prefix(8))"
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handle(message: message, blocked: blocked, follows: follows)
                }
                .store(in: &cancellables)

            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                var req: [Any] = ["REQ", subId]
                req.append(contentsOf: filters)
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }

        loadTimeout?.invalidate()
        loadTimeout = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishLoading() }
        }
    }

    func disconnect() {
        loadTimeout?.invalidate()
        loadTimeout = nil
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
    }

    /// Drops a stream from the grid without a refetch — used when the owner
    /// blocks its host from the player.
    func removeStreams(byHost pubkey: String) {
        collected = collected.filter { $0.value.hostPubkey != pubkey }
        streams = streams.filter { $0.hostPubkey != pubkey }
    }

    /// zap.stream is where most live events are published and is worth asking
    /// even when the owner has not configured it, since this feed is
    /// external-only by design.
    static var relayURLs: [URL] {
        var strings = ConfigService.shared.config.activeFeedRelays
        if strings.isEmpty { strings = ["wss://relay.primal.net", "wss://nos.lol"] }
        if !strings.contains(LiveChat.streamRelay) { strings.append(LiveChat.streamRelay) }
        return strings.compactMap { URL(string: $0) }
    }

    // MARK: - Private

    private func handle(message: String, blocked: Set<String>, follows: Set<String>?) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }

        if type == "EOSE" { publish(); return }

        guard type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let kind = event["kind"] as? Int,
              let tags = event["tags"] as? [[String]],
              kind == 30311,
              !blocked.contains(pubkey)
        else { return }

        if let follows, !LiveChat.isFollowed(authorPubkey: pubkey, tags: tags, follows: follows) { return }
        guard let stream = LiveStream(id: id, pubkey: pubkey, createdAt: createdAt, tags: tags),
              // A block on the streamer has to reach their service-published streams too.
              !blocked.contains(stream.zapPubkey)
        else { return }

        // Addressable: the newest event for an address wins, which is how a
        // stream that has since ended replaces its own live announcement.
        if let existing = collected[stream.address], existing.createdAt >= stream.createdAt { return }
        collected[stream.address] = stream
        publish()
    }

    private func publish() {
        streams = collected.values
            .filter { $0.isPlayableLive }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.address > $1.address
            }
        if !streams.isEmpty {
            isLoading = false
            loadFailed = false
        }
    }

    private func finishLoading() {
        isLoading = false
        loadFailed = streams.isEmpty && !followSetIsEmpty
        disconnect()
    }
}

/// A NIP-53 live event, reduced to what the grid and the player need.
struct LiveStream: Identifiable, Equatable {
    /// The 30311 event's own id, which a zap for this stream tags alongside
    /// the address.
    let eventId: String
    let hostPubkey: String
    let identifier: String
    let createdAt: Int64
    let title: String?
    let summary: String?
    let imageURL: URL?
    let streamingURL: URL?
    let status: String?
    let participants: Int?
    /// Relays the stream itself says its chat is on (NIP-53 `relays` tag).
    let chatRelays: [String]
    /// Who a zap pays. Usually the author, but zap.stream publishes on the
    /// host's behalf, and then the author is the service.
    let zapPubkey: String

    var address: String { LiveChat.address(hostPubkey: hostPubkey, identifier: identifier) }
    var id: String { address }

    /// Shown only when the stream is running AND something can play it.
    ///
    /// Measured 2026-09-05: 478 of 632 events were already `ended` and only 89
    /// carried a streaming tag at all, so without both halves of this test the
    /// grid is mostly gravestones. A missing status with a live URL counts —
    /// 71 events omit status entirely, which is a real bucket, not noise.
    var isPlayableLive: Bool {
        guard streamingURL != nil else { return false }
        guard let status else { return true }
        return status == "live"
    }

    init?(id: String, pubkey: String, createdAt: Int64, tags: [[String]]) {
        func value(_ name: String) -> String? {
            guard let raw = tags.first(where: { $0.count >= 2 && $0[0] == name })?[1] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let identifier = value("d") else { return nil }
        self.eventId = id
        self.hostPubkey = pubkey
        self.zapPubkey = LiveChat.hostPubkey(authorPubkey: pubkey, tags: tags)
        self.identifier = identifier
        self.createdAt = createdAt
        self.title = value("title")
        self.summary = value("summary")
        self.imageURL = value("image").flatMap { URL(string: $0) }
        self.status = value("status")
        // The whole tag is the list, not just its first value.
        self.chatRelays = (tags.first { $0.count >= 2 && $0[0] == "relays" }?.dropFirst())
            .map { $0.compactMap(LiveChat.normalizedRelay) } ?? []
        self.participants = value("current_participants").flatMap { Int($0) }

        // AVPlayer speaks HTTP(S). The sample also carried rtmp, ftp and a
        // `zapcast:` scheme — none of which it can open, so a tile for one is a
        // tile that can only disappoint.
        if let raw = value("streaming"), let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            self.streamingURL = url
        } else {
            self.streamingURL = nil
        }
    }
}

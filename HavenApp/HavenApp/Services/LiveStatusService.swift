import Foundation
import Combine

/// Which accounts are live right now (NIP-53 kind 30311), for the red ring on
/// their profile picture.
///
/// Avatars ask by appearing: `watch` collects the pubkeys on screen and, after
/// a short pause, sends one REQ for the ones not asked about in the last few
/// minutes — by author and by `p` tag, since services like zap.stream publish
/// streams under their own key with the streamer as Host. Like the Live tab,
/// nothing is saved to the device's relay; a stream only matters while it runs.
@MainActor
final class LiveStatusService: ObservableObject {
    static let shared = LiveStatusService()

    /// Pubkeys hosting a live, playable stream. Republished only when the set
    /// changes, so avatars do not redraw for every event that arrives.
    @Published private(set) var liveHosts: Set<String> = []

    private var book = LiveStatusBook()
    private var pending = Set<String>()
    private var flushScheduled = false
    private var account: String?

    /// Pause before a batch goes out, so a screenful of avatars is one REQ.
    private static let batchDelay = RelayRequestBudget.liveRingBatchDelay
    /// Relays cap filter sizes; larger batches are split.
    private static let maxPerFilter = 150
    /// A lookup is closed after this, answered or not.
    private static let lookupTimeout: TimeInterval = 10

    private init() {}

    /// The stream `pubkey` is hosting right now, if any.
    func stream(hostedBy pubkey: String) -> LiveStream? {
        guard liveHosts.contains(pubkey),
              let event = book.liveEvent(hostedBy: pubkey, at: Self.now) else { return nil }
        return LiveStream(id: event.id, pubkey: event.pubkey, createdAt: event.createdAt, tags: event.tags)
    }

    /// An avatar for `pubkey` is on screen.
    func watch(_ pubkey: String) {
        guard pubkey.count == 64 else { return }
        resetIfAccountChanged()
        pending.insert(pubkey)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
            self?.flush()
        }
    }

    // MARK: - Private

    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    private func resetIfAccountChanged() {
        let current = FeedService.shared.currentSnapshotKey()
        guard current != account else { return }
        account = current
        book.reset()
        if !liveHosts.isEmpty { liveHosts = [] }
    }

    private func flush() {
        flushScheduled = false
        let due = book.takeDue(pending, now: Date())
        pending.removeAll()
        // A stream can end between lookups; drop rings that have gone stale.
        republish()
        guard !due.isEmpty else { return }

        var filters: [[String: Any]] = []
        for start in stride(from: 0, to: due.count, by: Self.maxPerFilter) {
            let chunk = Array(due[start..<min(start + Self.maxPerFilter, due.count)])
            filters.append(["kinds": [30311], "authors": chunk, "limit": 50])
            filters.append(["kinds": [30311], "#p": chunk, "limit": 50])
        }
        // On the shared lookup sockets: a flush used to dial every ring
        // relay again (NV_HEALTH_C3). Each lookup ends at its EOSE.
        let subId = "ring-\(UUID().uuidString.prefix(8))"
        let relays = RelayRequestBudget.liveRingRelays(feedRelays: ConfigService.shared.config.activeFeedRelays)
        for url in relays.compactMap({ URL(string: $0) }) {
            LookupSocketPool.shared.query(url: url, subId: subId, filters: filters, timeout: Self.lookupTimeout,
                                          onMessage: { [weak self] message in self?.handle(message) })
        }
    }

    private func handle(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 3, json[0] as? String == "EVENT",
              let event = json[2] as? [String: Any],
              event["kind"] as? Int == 30311,
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let tags = event["tags"] as? [[String]]
        else { return }
        if book.ingest(.init(id: id, pubkey: pubkey, createdAt: createdAt, tags: tags)) { republish() }
    }

    private func republish() {
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let hosts = book.liveHosts(at: Self.now).subtracting(blocked)
        if hosts != liveHosts { liveHosts = hosts }
    }
}

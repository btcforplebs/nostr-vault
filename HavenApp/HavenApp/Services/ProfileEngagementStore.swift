import Foundation

/// Likes, reposts, replies and zap sats for the posts on a profile, fetched
/// as soon as the profile shows them so the numbers are just there.
///
/// One batched query per page of posts, not one per row: the engagement on a
/// person's posts lands on their inbox relays (NIP-65), so those are asked
/// first, with the feed relays as a fallback. Session-only; nothing persisted.
@MainActor
final class ProfileEngagementStore: ObservableObject {
    static let shared = ProfileEngagementStore()
    private init() {}

    @Published private(set) var counts: [String: PostEngagement] = [:]

    /// When each post's counts were last asked for, so scrolling back and
    /// forth doesn't re-ask the relays.
    private var fetchedAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    private let freshFor: TimeInterval = 5 * 60

    func engagement(for id: String) -> PostEngagement? { counts[id] }

    /// Loads counts for `ids`, posts by `author`.
    /// - Parameter force: ask again even for posts fetched a moment ago
    ///   (pull-to-refresh). Numbers on screen still never go down.
    func load(ids: [String], author: String, force: Bool = false) async {
        let now = Date()
        let due = ids.filter { id in
            !inFlight.contains(id) && (force || fetchedAt[id].map { now.timeIntervalSince($0) > freshFor } ?? true)
        }
        guard !due.isEmpty else { return }
        inFlight.formUnion(due)
        defer { inFlight.subtract(due) }

        let relays = Self.relays(for: author)
        guard !relays.isEmpty else { return }
        let targets = Set(due)
        let events = await ZapHistoryService.query(
            filters: PostEngagementQuery.filters(for: due),
            relays: relays,
            timeout: 6,
            onProgress: { [weak self] partial in
                // Counts fill in as each relay answers rather than all at the
                // end. ZapHistoryService calls this on the main queue.
                MainActor.assumeIsolated {
                    self?.apply(PostEngagementQuery.tally(partial, targets: targets))
                }
            })
        apply(PostEngagementQuery.tally(events, targets: targets))
        let done = Date()
        for id in due { fetchedAt[id] = done }
    }

    private func apply(_ found: [String: PostEngagement]) {
        guard !found.isEmpty else { return }
        var next = counts
        for (id, e) in found {
            next[id] = next[id].map { $0.merged(with: e) } ?? e
        }
        if next != counts { counts = next }
    }

    /// The author's inbox relays first (where reactions, replies and zap
    /// receipts are sent), then their write relays, then the feed relays.
    /// For your own profile, your own embedded inbox relay, which already
    /// holds what was sent to you.
    private static func relays(for author: String) -> [URL] {
        let config = ConfigService.shared.config
        let nostr = NostrService.shared
        if nostr.relayLists[author] == nil { nostr.fetchRelayList(for: author) }

        var strings: [String] = []
        if author == nostr.activeHexPubkey,
           RelayProcessManager.shared.isRunning, !RelayProcessManager.shared.isBooting {
            strings.append(config.nostrURL + "/inbox")
        }
        strings += (nostr.relayLists[author] ?? []).prefix(3)
        strings += (nostr.outboxRelays[author] ?? []).prefix(2)
        strings += config.activeFeedRelays.isEmpty ? ["wss://relay.primal.net", "wss://nos.lol"] : config.activeFeedRelays

        var seen = Set<String>()
        return strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted }
            .prefix(6)
            .compactMap { URL(string: $0) }
    }
}

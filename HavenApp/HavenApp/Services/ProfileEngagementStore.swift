import Foundation

/// Likes, reposts, replies, quotes and zap sats for the posts on a profile: best
/// effort from relays, kept on the phone so they aren't pulled again.
///
/// Each post's ledger (who liked, reposted, replied, zapped) is saved. The
/// first visit asks relays for everything; later visits ask only for what's
/// newer than the last check and add it, so numbers climb toward the real
/// total across visits without anything counted twice. One batched query per
/// page of posts, to the author's inbox relays (NIP-65) first, then their
/// write relays and the feed relays.
@MainActor
final class ProfileEngagementStore: ObservableObject {
    static let shared = ProfileEngagementStore()
    private init() { ledgers = Self.loadFromDisk() }

    @Published private(set) var ledgers: [String: EngagementLedger] = [:]
    private var inFlight = Set<String>()
    private var saveScheduled = false

    /// A post checked this recently isn't asked about again.
    private let freshFor: TimeInterval = 5 * 60
    /// Likes created shortly before the last check can still be on their way
    /// to a relay; the next ask reaches back this far. The ledger drops repeats.
    private let sinceSlack: TimeInterval = 15 * 60
    /// Ledgers kept on disk, most recently checked first.
    private let maxLedgers = 3_000

    func engagement(for id: String) -> PostEngagement? {
        guard let e = ledgers[id]?.engagement, !e.isEmpty else { return nil }
        return e
    }

    /// Loads counts for `ids`, posts by `author`.
    /// - Parameter force: ask again even for posts checked a moment ago
    ///   (pull-to-refresh). Still only for what's new.
    func load(ids: [String], author: String, force: Bool = false) async {
        let now = Date()
        let due = ids.filter { id in
            !inFlight.contains(id) && (force || ledgers[id]?.checkedAt.map { now.timeIntervalSince($0) > freshFor } ?? true)
        }
        guard !due.isEmpty else { return }
        inFlight.formUnion(due)
        defer { inFlight.subtract(due) }

        let relays = Self.relays(for: author)
        guard !relays.isEmpty else { return }
        // Your own posts, with your inbox relay asked, are counted from what
        // was sent to you; anything else may be missing likes on other relays.
        let lowerBound = !relays.contains { $0.absoluteString.hasSuffix("/inbox") }

        // A ledger saved before quotes were counted (quotes nil) is asked
        // about in full once; the ledger drops everything it already holds.
        let isKnown = { (id: String) in self.ledgers[id]?.checkedAt != nil && self.ledgers[id]?.quotes != nil }
        let fresh = due.filter { !isKnown($0) }
        let known = due.filter(isKnown)
        var filters = PostEngagementQuery.filters(for: fresh)
        if let oldest = known.compactMap({ ledgers[$0]?.checkedAt }).min() {
            filters += PostEngagementQuery.filters(for: known, since: Int(oldest.addingTimeInterval(-sinceSlack).timeIntervalSince1970))
        }

        let targets = Set(due)
        let events = await ZapHistoryService.query(
            filters: filters,
            relays: relays,
            timeout: 6,
            onProgress: { [weak self] partial in
                // Counts fill in as each relay answers rather than all at the
                // end. ZapHistoryService calls this on the main queue.
                MainActor.assumeIsolated {
                    self?.absorb(PostEngagementQuery.contributions(partial, targets: targets), lowerBound: lowerBound, checkedAt: nil)
                }
            })
        absorb(PostEngagementQuery.contributions(events, targets: targets), lowerBound: lowerBound, checkedAt: now,
               checked: due)
    }

    /// - Parameter checked: posts to stamp as asked about at `checkedAt`,
    ///   including ones nobody engaged with, so they aren't asked about again
    ///   until they go stale.
    private func absorb(_ found: [String: EngagementLedger], lowerBound: Bool, checkedAt: Date?, checked: [String] = []) {
        var next = ledgers
        for (id, seen) in found {
            var ledger = next[id] ?? EngagementLedger()
            ledger.absorb(seen)
            if !lowerBound { ledger.isLowerBound = false }
            next[id] = ledger
        }
        if let checkedAt {
            for id in checked {
                var ledger = next[id] ?? EngagementLedger()
                ledger.checkedAt = checkedAt
                if !lowerBound { ledger.isLowerBound = false }
                next[id] = ledger
            }
        }
        guard next != ledgers else { return }
        ledgers = next
        scheduleSave()
    }

    // MARK: Disk

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("engagement_ledgers.json")
    }

    private static func loadFromDisk() -> [String: EngagementLedger] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: EngagementLedger].self, from: data)) ?? [:]
    }

    /// Writes at most every few seconds; a profile page fills in many rows at once.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    private func save() {
        saveScheduled = false
        var kept = ledgers
        if kept.count > maxLedgers {
            let newest = kept.sorted { ($0.value.checkedAt ?? .distantPast) > ($1.value.checkedAt ?? .distantPast) }
                .prefix(maxLedgers)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            ledgers = kept
        }
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(kept) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Relays

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
        strings += config.readRelays

        var seen = Set<String>()
        return strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted }
            .prefix(6)
            .compactMap { URL(string: $0) }
    }
}

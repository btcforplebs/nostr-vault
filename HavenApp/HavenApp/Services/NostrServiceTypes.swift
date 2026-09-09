import Foundation

/// Types and constants extracted from NostrService for portability.
/// No @Published, no Combine, no SwiftUI — pure Foundation.

/// Wrapper to pass non-Sendable types across isolation boundaries.
/// Used internally for filter dictionaries sent into async task groups.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

/// Parsed results of a NIP-50 global search.
struct GlobalSearchResults {
    var profiles: [FeedProfile] = []
    var notes: [FeedNote] = []
}

/// Lightweight signal published when profile metadata changes, so views can
/// re-resolve ONLY the affected rows instead of rebuilding everything.
struct ProfileUpdateSignal: Equatable {
    var generation: Int = 0
    var pubkeys: Set<String> = []
}

/// Public NIP-50 search-capable relays queried for global search.
let nip50SearchRelays = [
    "wss://relay.nostr.band",
    "wss://relay.noswhere.com"
]

// MARK: - Global Search Collector

/// Thread-safe accumulator for NIP-50 global search results. EVENT messages
/// from multiple relays are deduplicated by id (notes) / pubkey (profiles).
final class GlobalSearchCollector {
    private let lock = NSLock()
    private var notes: [String: FeedNote] = [:]
    private var profiles: [String: FeedProfile] = [:]

    func ingest(message: String, subId: String) {
        guard let data = message.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 3,
              let type = arr[0] as? String, type == "EVENT",
              let sid = arr[1] as? String, sid == subId,
              let ev = arr[2] as? [String: Any],
              let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let kind = (ev["kind"] as? NSNumber)?.intValue,
              let content = ev["content"] as? String else { return }
        let createdAt = (ev["created_at"] as? NSNumber)?.int64Value ?? 0
        let tags = (ev["tags"] as? [[String]]) ?? []

        lock.lock()
        defer { lock.unlock() }

        if kind == 1 {
            guard notes[id] == nil else { return }
            notes[id] = FeedNote(
                id: id,
                pubkey: pubkey,
                content: content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                tags: tags,
                kind: kind
            )
        } else if kind == 0 {
            guard let metadata = try? JSONSerialization.jsonObject(with: content.data(using: .utf8) ?? Data()) as? [String: Any] else { return }
            var profile = FeedProfile(pubkey: pubkey)
            profile.name = metadata["name"] as? String
            profile.displayName = metadata["display_name"] as? String
            profile.pictureURL = (metadata["picture"] as? String).flatMap { URL(string: $0) }
            profile.nip05 = metadata["nip05"] as? String
            profile.about = metadata["about"] as? String
            profile.lud16 = metadata["lud16"] as? String
            profile.lud06 = metadata["lud06"] as? String
            profile.website = metadata["website"] as? String
            profiles[pubkey] = profile
        }
    }

    func snapshot() -> GlobalSearchResults {
        lock.lock()
        defer { lock.unlock() }
        var results = GlobalSearchResults()
        results.notes = notes.values.sorted { $0.createdAt > $1.createdAt }
        results.profiles = Array(profiles.values)
        return results
    }
}

// MARK: - Local Relay Search Collector

/// Accumulates relay-mode search results while paging the local relay.
///
/// Differs from `GlobalSearchCollector` in three ways that paging needs:
/// it filters at ingest time (only matches are retained, so a 30,000-event
/// walk stays flat in memory), it keeps per-subscription page statistics so
/// the pager can decide whether to ask for another page, and it reports EOSE
/// — which is what lets a search finish as soon as the relay is done instead
/// of waiting out a fixed timer.
final class LocalRelaySearchCollector {
    enum Signal: Equatable {
        case ignored
        case event(subId: String)
        case eose(subId: String)
    }

    struct PageStats: Equatable {
        var received = 0
        var newIds = 0
        var oldestCreatedAt: Int64?
    }

    private let lock = NSLock()
    private let matcher: LocalSearchMatcher
    private var notes: [String: FeedNote] = [:]
    private var profiles: [String: FeedProfile] = [:]
    private var seenIds = Set<String>()
    private var stats: [String: PageStats] = [:]

    init(matcher: LocalSearchMatcher) {
        self.matcher = matcher
    }

    @discardableResult
    func ingest(message: String) -> Signal {
        guard let data = message.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 2,
              let type = arr[0] as? String,
              let subId = arr[1] as? String else { return .ignored }

        if type == "EOSE" { return .eose(subId: subId) }

        guard type == "EVENT",
              arr.count >= 3,
              let ev = arr[2] as? [String: Any],
              let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let kind = (ev["kind"] as? NSNumber)?.intValue,
              let content = ev["content"] as? String else { return .ignored }

        let createdAt = (ev["created_at"] as? NSNumber)?.int64Value ?? 0
        let tags = (ev["tags"] as? [[String]]) ?? []

        lock.lock()
        defer { lock.unlock() }

        var page = stats[subId] ?? PageStats()
        page.received += 1
        if page.oldestCreatedAt == nil || createdAt < page.oldestCreatedAt! {
            page.oldestCreatedAt = createdAt
        }
        let isNew = seenIds.insert(id).inserted
        if isNew { page.newIds += 1 }
        stats[subId] = page

        guard isNew else { return .event(subId: subId) }

        if kind == 1 {
            if matcher.matchesNote(content: content) {
                notes[id] = FeedNote(
                    id: id,
                    pubkey: pubkey,
                    content: content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                    tags: tags,
                    kind: kind
                )
            }
        } else if kind == 0 {
            guard let metadata = try? JSONSerialization.jsonObject(
                with: content.data(using: .utf8) ?? Data()) as? [String: Any] else {
                return .event(subId: subId)
            }
            var profile = FeedProfile(pubkey: pubkey)
            profile.name = metadata["name"] as? String
            profile.displayName = metadata["display_name"] as? String
            profile.pictureURL = (metadata["picture"] as? String).flatMap { URL(string: $0) }
            profile.nip05 = metadata["nip05"] as? String
            profile.about = metadata["about"] as? String
            profile.lud16 = metadata["lud16"] as? String
            profile.lud06 = metadata["lud06"] as? String
            profile.website = metadata["website"] as? String
            if matcher.matchesProfile(displayName: profile.displayName,
                                      name: profile.name,
                                      about: profile.about,
                                      nip05: profile.nip05,
                                      pubkey: pubkey) {
                profiles[pubkey] = profile
            }
        }

        return .event(subId: subId)
    }

    /// Page statistics for a subscription, and clears them so the next page
    /// starts from zero.
    func takeStats(for subId: String) -> PageStats {
        lock.lock()
        defer { lock.unlock() }
        let page = stats[subId] ?? PageStats()
        stats[subId] = nil
        return page
    }

    /// Adds profiles the app already holds in memory. The local relay stores no
    /// kind-0 for anyone but the owner (import pulls owner-authored events only,
    /// the inbox needs a `p` tag, and `/feed` accepts kinds 1/6/30023), so
    /// without this a search by username can only ever find the owner.
    func addCachedProfiles(_ cached: [String: FeedProfile]) {
        lock.lock()
        defer { lock.unlock() }
        for (pubkey, profile) in cached where profiles[pubkey] == nil {
            if matcher.matchesProfile(displayName: profile.displayName,
                                      name: profile.name,
                                      about: profile.about,
                                      nip05: profile.nip05,
                                      pubkey: pubkey) {
                profiles[pubkey] = profile
            }
        }
    }

    func snapshot() -> GlobalSearchResults {
        lock.lock()
        defer { lock.unlock() }
        var results = GlobalSearchResults()
        results.notes = notes.values.sorted { $0.createdAt > $1.createdAt }
        results.profiles = Array(profiles.values)
        return results
    }
}

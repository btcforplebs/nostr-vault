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

/// Default public NIP-50 search-capable relays. Used as the fallback when the
/// user has not configured their own search relays (`HavenConfig.searchRelays`).
let nip50SearchRelays = [
    "wss://relay.nostr.band",
    "wss://relay.noswhere.com",
    "wss://search.nos.today"
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

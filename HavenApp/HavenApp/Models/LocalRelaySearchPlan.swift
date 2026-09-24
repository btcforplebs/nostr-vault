import Foundation

/// Planning + matching rules for relay-mode search ("search my own relay").
///
/// The embedded relay's backend caps every REQ, and a filter asking for MORE
/// than the cap is not clamped down to it — it falls through to `cap / 4`.
/// The two backends have different caps:
///
/// - LMDB: `MaxLimit` 1500 (`eventstore/lmdb/lib.go:46`), so 2000 returns 375.
/// - Badger (`DB_ENGINE=badger`, what the iOS installs actually run): `MaxLimit`
///   1000 (`eventstore/badger/lib.go:63`), so the old page of 1500 returned
///   250, which read as a short page and ended every search after the newest
///   250 events of each kind.
///
/// ```go
/// limit = maxLimit / 4
/// if filter.Limit > 0 && filter.Limit <= maxLimit {
///     limit = filter.Limit
/// }
/// ```
///
/// So a page must fit under the smaller cap, and covering the whole store means
/// paging with an `until` cursor, not a bigger number.
enum LocalRelaySearchPlan {
    /// Largest limit every backend honours verbatim (Badger's 1000; LMDB's is 1500).
    static let relayMaxLimit = 1000

    /// Events requested per page. Must stay <= `relayMaxLimit`.
    static let pageLimit = relayMaxLimit

    /// Bounds one search: 40 pages x 1000 = 40,000 events per route and kind.
    static let maxPages = 40

    /// What to do once a page has been received in full (EOSE).
    enum Step: Equatable {
        case done
        case next(until: Int64)
    }

    /// Decides whether another page is worth asking for.
    ///
    /// - Parameters:
    ///   - received: events delivered for this page, before de-duplication.
    ///   - newIds: how many of those had not already arrived on an earlier page.
    ///   - oldestCreatedAt: smallest `created_at` seen in this page.
    ///   - pagesFetched: pages fetched so far, including this one.
    static func step(received: Int,
                     newIds: Int,
                     oldestCreatedAt: Int64?,
                     pagesFetched: Int) -> Step {
        // A short page means the store had nothing more to give.
        guard received >= pageLimit else { return .done }
        // `until` is inclusive, so a page of pure repeats means the cursor
        // cannot advance (every event shares one timestamp) — stop rather than
        // ask for the same page forever.
        guard newIds > 0 else { return .done }
        guard pagesFetched < maxPages else { return .done }
        guard let oldest = oldestCreatedAt else { return .done }
        return .next(until: oldest)
    }
}

/// Case-insensitive substring matching for relay-mode search. One definition,
/// used for events pulled off the relay and for profiles already held in the
/// app's in-memory cache, so the two cannot drift apart.
struct LocalSearchMatcher {
    let needle: String

    /// Fails for queries shorter than two characters: the relay-mode search is a
    /// substring scan, and a one-character needle matches nearly everything.
    /// (Swift's `"sarah".contains("")` is `false`, but do not rest on that.)
    init?(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        self.needle = trimmed.lowercased()
    }

    /// A note matches on its own text and nothing else. Searching a person's
    /// name finds that person under Users; it deliberately does not sweep in
    /// everything they wrote (Logen, 2026-09-09). Hashtags and links are
    /// derived from the notes this keeps.
    func matchesNote(content: String) -> Bool {
        content.lowercased().contains(needle)
    }

    func matchesProfile(displayName: String?,
                        name: String?,
                        about: String?,
                        nip05: String?,
                        pubkey: String) -> Bool {
        for field in [displayName, name, about, nip05] {
            if let field, field.lowercased().contains(needle) { return true }
        }
        return pubkey.lowercased().contains(needle)
    }
}

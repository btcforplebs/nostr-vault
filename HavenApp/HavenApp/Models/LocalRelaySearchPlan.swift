import Foundation

/// Planning + matching rules for relay-mode search ("search my own relay").
///
/// The embedded relay stores events in LMDB, and its backend caps every REQ.
/// `MaxLimit` is left at the library default of 1500
/// (`eventstore/lmdb/lib.go:46`), and a filter asking for MORE than that is not
/// clamped down to 1500 — it falls through to `maxLimit / 4` = 375
/// (`eventstore/lmdb/query.go:27-37`):
///
/// ```go
/// limit = maxLimit / 4
/// if filter.Limit > 0 && filter.Limit <= maxLimit {
///     limit = filter.Limit
/// }
/// ```
///
/// So one REQ can never cover a store larger than 1500 events, asking for 2000
/// silently returns 375, and omitting the limit returns 375 as well. Covering
/// the whole store means paging with an `until` cursor, not a bigger number.
enum LocalRelaySearchPlan {
    /// Largest limit the LMDB backend honours verbatim.
    static let relayMaxLimit = 1500

    /// Events requested per page. Must stay <= `relayMaxLimit`.
    static let pageLimit = relayMaxLimit

    /// Bounds one search: 20 pages x 1500 = 30,000 events per route and kind.
    static let maxPages = 20

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

    func matchesNote(content: String) -> Bool {
        content.lowercased().contains(needle)
    }

    /// The whole rule for keeping a note: its text matches, or its author's
    /// profile matched the query. Searching a person's name is meant to find
    /// what that person wrote, not just their profile card. One definition,
    /// used by the relay walk and by the in-memory fallback.
    func matchesNote(content: String, authorPubkey: String, matchedAuthors: Set<String>) -> Bool {
        matchesNote(content: content) || matchedAuthors.contains(authorPubkey)
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

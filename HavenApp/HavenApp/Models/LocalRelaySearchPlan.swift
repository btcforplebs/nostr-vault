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
    ///   - until: the `until` this page was requested with (nil for the first).
    static func step(received: Int,
                     newIds: Int,
                     oldestCreatedAt: Int64?,
                     pagesFetched: Int,
                     until: Int64? = nil) -> Step {
        // A short page means the store had nothing more to give.
        guard received >= pageLimit else { return .done }
        guard pagesFetched < maxPages else { return .done }
        guard let oldest = oldestCreatedAt else { return .done }
        guard newIds > 0 else {
            // `until` is inclusive, so a full page of repeats sitting on the
            // second it was asked for means more than a page of events share
            // that second. Step past it rather than stop the walk there (or
            // ask for the same page forever) — what haven-go's search.go
            // does; the rest of that one second goes unsearched.
            if let until, oldest == until, oldest > 0 {
                return .next(until: oldest - 1)
            }
            return .done
        }
        return .next(until: oldest)
    }
}

/// Case-insensitive substring matching for relay-mode search. One definition,
/// used for events pulled off the relay and for profiles already held in the
/// app's in-memory cache, so the two cannot drift apart.
struct LocalSearchMatcher {
    let needle: String
    /// Set for Global search's own-store sources: every term must appear,
    /// in any order. Relay mode leaves it nil and keeps its whole-phrase
    /// substring match.
    let allTerms: SearchTermMatcher?

    /// Fails for queries shorter than two characters: the relay-mode search is a
    /// substring scan, and a one-character needle matches nearly everything.
    /// (Swift's `"sarah".contains("")` is `false`, but do not rest on that.)
    init?(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        self.needle = trimmed.lowercased()
        self.allTerms = nil
    }

    /// All-terms matching (case-insensitive) — what Global search uses to
    /// verify hits from the phone's store and the Mac relay.
    init?(allTermsOf query: String) {
        guard let terms = SearchTermMatcher(query: query) else { return nil }
        self.needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.allTerms = terms
    }

    /// A note matches on its own text and nothing else. Searching a person's
    /// name finds that person under Users; it deliberately does not sweep in
    /// everything they wrote (Logen, 2026-09-09). Hashtags and links are
    /// derived from the notes this keeps.
    func matchesNote(content: String) -> Bool {
        if let allTerms { return allTerms.matches(content) }
        return content.lowercased().contains(needle)
    }

    /// As `matchesNote(content:)`, but in all-terms mode the `title` /
    /// `summary` / `subject` tags count too, as they do on the server.
    /// Relay mode ignores the tags and matches exactly as before.
    func matchesNote(content: String, tags: [[String]]) -> Bool {
        if let allTerms { return allTerms.matchesNote(content: content, tags: tags) }
        return matchesNote(content: content)
    }

    func matchesProfile(displayName: String?,
                        name: String?,
                        about: String?,
                        nip05: String?,
                        pubkey: String) -> Bool {
        if let allTerms {
            return allTerms.matches(fields: [displayName, name, about, nip05, pubkey])
        }
        for field in [displayName, name, about, nip05] {
            if let field, field.lowercased().contains(needle) { return true }
        }
        return pubkey.lowercased().contains(needle)
    }
}

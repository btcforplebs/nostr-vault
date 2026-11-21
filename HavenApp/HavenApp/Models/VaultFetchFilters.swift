import Foundation

enum VaultFetchFilters {
    /// Others' likes, generic reposts and zap receipts that tag you.
    static let taggedEngagementKinds = [7, 16, 9735]
    /// Same as Android's PAGE and OLDER_PAGE (VaultActivityViewModel).
    static let engagementLimit = 500
    static let engagementOlderLimit = 200

    /// The Vault's read: the socket REQ and the direct store read
    /// (NostrService+VaultDirectRead) ask the same filters. `noteKinds` is
    /// NostrService.relayTabNoteKinds.
    ///
    /// Split note kinds from engagement/metadata kinds. The relay returns the
    /// newest N events PER FILTER regardless of kind, so a single all-kinds
    /// filter lets a high volume of reactions/zaps crowd actual notes out of
    /// the window on cold start (notes are cached but never loaded into memory).
    /// Giving notes their own filter guarantees they load independent of how
    /// many reactions/zaps share the window — same rationale as bounding
    /// long-form bodies separately.
    static func filters(ownerHex: String, authors: [String]?, until: Int64?, since: Int64?,
                        noteKinds: [Int]) -> [[String: Any]] {
        let isHistorical = until != nil
        let metaKinds = [0, 3, 4, 7, 1063, 9735, 10000, 10063]
        let noteLimit = isHistorical ? 100 : 400
        let metaLimit = isHistorical ? 100 : 200
        let tagLimit = isHistorical ? engagementOlderLimit : engagementLimit

        func makeFilter(kinds: [Int], limit: Int, mentionsOwner: String?) -> [String: Any] {
            var f: [String: Any] = ["limit": limit, "kinds": kinds]
            if let until = until { f["until"] = until }
            if let since = since { f["since"] = since }
            // Author scoping applies to the owner/whitelist feed, not the mentions feed.
            if mentionsOwner == nil, let authors = authors, !authors.isEmpty {
                f["authors"] = authors
            }
            if let owner = mentionsOwner {
                f["#p"] = [owner]
            }
            return f
        }

        // Owner/whitelist feed: notes get a generous limit, engagement/metadata its own.
        var filters: [[String: Any]] = [
            makeFilter(kinds: noteKinds, limit: noteLimit, mentionsOwner: nil),
            makeFilter(kinds: metaKinds, limit: metaLimit, mentionsOwner: nil),
        ]

        // CRITICAL: Always subscribe to mentions (#p) of the owner so "tagged notes"
        // from people we don't follow still show up in the viewer. Split the same way
        // so replies aren't starved by reactions/zaps tagging the owner.
        //
        // Likes, reposts and zaps that tag you get their own filter, as on
        // Android (TAGGED_KINDS, PAGE 500): in the shared 200-cap one, every
        // follower's kind 3 list and kind 4 DM that tags you pushed them out,
        // and the Vault showed no likes (Logen 2026-11-21).
        if !ownerHex.isEmpty {
            filters.append(makeFilter(kinds: noteKinds, limit: noteLimit, mentionsOwner: ownerHex))
            filters.append(makeFilter(kinds: taggedEngagementKinds, limit: tagLimit, mentionsOwner: ownerHex))
            filters.append(makeFilter(kinds: metaKinds.filter { !taggedEngagementKinds.contains($0) },
                                      limit: metaLimit, mentionsOwner: ownerHex))
        }
        return filters
    }
}

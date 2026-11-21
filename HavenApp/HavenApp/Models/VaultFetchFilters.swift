import Foundation

enum VaultFetchFilters {
    /// Others' likes, generic reposts and zap receipts that tag you.
    static let taggedEngagementKinds = [7, 16, 9735]
    /// Same as Android's PAGE and OLDER_PAGE (VaultActivityViewModel).
    static let engagementLimit = 500
    static let engagementOlderLimit = 200
    static let metaKinds = [0, 3, 4, 7, 1063, 9735, 10000, 10063]

    /// One filter of the Vault's read. Load older pages each one from its own
    /// oldest event, as Android does for its two (VaultActivityViewModel
    /// loadMore): one cursor for every kind let a stream that reaches far back
    /// (notes, 400) skip what a shorter one (likes) held in between.
    enum Stream: CaseIterable {
        case ownNotes, ownMeta, taggedNotes, taggedEngagement, taggedMeta

        var tagsOwner: Bool { self == .taggedNotes || self == .taggedEngagement || self == .taggedMeta }

        func kinds(noteKinds: [Int]) -> [Int] {
            switch self {
            case .ownNotes, .taggedNotes: return noteKinds
            case .ownMeta: return VaultFetchFilters.metaKinds
            case .taggedEngagement: return VaultFetchFilters.taggedEngagementKinds
            case .taggedMeta: return VaultFetchFilters.metaKinds.filter { !VaultFetchFilters.taggedEngagementKinds.contains($0) }
            }
        }

        func limit(older: Bool) -> Int {
            switch self {
            case .ownNotes, .taggedNotes: return older ? 100 : 400
            case .ownMeta, .taggedMeta: return older ? 100 : 200
            case .taggedEngagement: return older ? VaultFetchFilters.engagementOlderLimit : VaultFetchFilters.engagementLimit
            }
        }
    }

    /// What a loaded event needs for the cursors.
    struct Loaded {
        let kind: Int
        let pubkey: String
        let createdAt: Int64
        /// Has a `p` tag for the owner.
        let tagsOwner: Bool
    }

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
    ///
    /// Owner/whitelist feed: notes get a generous limit, engagement/metadata
    /// its own. CRITICAL: always subscribe to mentions (#p) of the owner so
    /// "tagged notes" from people we don't follow still show up, split the
    /// same way so replies aren't starved by reactions/zaps tagging the owner.
    ///
    /// Likes, reposts and zaps that tag you get their own filter, as on
    /// Android (TAGGED_KINDS, PAGE 500): in the shared 200-cap one, every
    /// follower's kind 3 list and kind 4 DM that tags you pushed them out,
    /// and the Vault showed no likes (Logen 2026-11-21).
    static func filters(ownerHex: String, authors: [String]?, since: Int64?,
                        noteKinds: [Int]) -> [[String: Any]] {
        streams(ownerHex: ownerHex).map {
            filter($0, ownerHex: ownerHex, authors: authors, noteKinds: noteKinds, until: nil, since: since)
        }
    }

    /// Load older: each stream from just before its own oldest loaded event.
    /// A stream with nothing loaded is not asked: its first page came back
    /// empty, so there is nothing older either.
    static func olderFilters(ownerHex: String, authors: [String]?, noteKinds: [Int],
                             cursors: [Stream: Int64]) -> [[String: Any]] {
        streams(ownerHex: ownerHex).compactMap { stream in
            guard let until = cursors[stream] else { return nil }
            return filter(stream, ownerHex: ownerHex, authors: authors, noteKinds: noteKinds, until: until, since: nil)
        }
    }

    /// Each stream's cursor: one second before the oldest loaded event that
    /// stream's filter matches. `skipKinds` are kinds paged on their own
    /// elsewhere (the Vault tab's Articles and Highlights).
    static func olderCursors(_ loaded: [Loaded], ownerHex: String, authors: [String]?, noteKinds: [Int],
                             skipKinds: Set<Int> = []) -> [Stream: Int64] {
        let authorSet = Set(authors ?? [])
        var cursors: [Stream: Int64] = [:]
        for stream in streams(ownerHex: ownerHex) {
            let kinds = Set(stream.kinds(noteKinds: noteKinds)).subtracting(skipKinds)
            let oldest = loaded.lazy.filter { e in
                guard kinds.contains(e.kind) else { return false }
                if stream.tagsOwner { return e.tagsOwner }
                return authorSet.isEmpty || authorSet.contains(e.pubkey)
            }.map(\.createdAt).min()
            if let oldest { cursors[stream] = oldest - 1 }
        }
        return cursors
    }

    private static func streams(ownerHex: String) -> [Stream] {
        ownerHex.isEmpty ? [.ownNotes, .ownMeta] : Stream.allCases
    }

    private static func filter(_ stream: Stream, ownerHex: String, authors: [String]?, noteKinds: [Int],
                               until: Int64?, since: Int64?) -> [String: Any] {
        var f: [String: Any] = ["limit": stream.limit(older: until != nil), "kinds": stream.kinds(noteKinds: noteKinds)]
        if let until { f["until"] = until }
        if let since { f["since"] = since }
        if stream.tagsOwner {
            f["#p"] = [ownerHex]
        } else if let authors, !authors.isEmpty {
            // Author scoping applies to the owner/whitelist feed, not the mentions feed.
            f["authors"] = authors
        }
        return f
    }
}

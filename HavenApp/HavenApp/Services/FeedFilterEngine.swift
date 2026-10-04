import Foundation

/// Pure filtering and sorting functions for the feed pipeline.
/// All inputs are explicit parameters — no @Published, no Combine, no singletons.
/// Direct translation target for Kotlin (pure functions -> pure functions).
enum FeedFilterEngine {

    // MARK: - Blocked Authors

    /// Whether a row would put a blocked person in front of the user. Checking
    /// `note.pubkey` alone missed most of it: a bare kind-6 repost carries the
    /// reposter as its pubkey and shows the original author's post, an
    /// embedded one swaps in the original author and keeps the reposter in
    /// `repostedBy`, and a reply shows the post it answers above itself.
    ///
    /// - Parameters:
    ///   - authorOf: looks up the author of a referenced event ID, or nil when
    ///     that event has not loaded. A bare repost falls back to its `p` tag.
    static func involvesBlocked(
        _ note: FeedNote,
        blocked: Set<String>,
        authorOf: (String) -> String? = { _ in nil }
    ) -> Bool {
        guard !blocked.isEmpty else { return false }
        if blocked.contains(note.pubkey) { return true }
        if let reposter = note.repostedBy, blocked.contains(reposter) { return true }
        if note.kind == 6, let originalId = note.repostedEventId {
            let original = authorOf(originalId)
                ?? note.tags.first { $0.count >= 2 && $0[0] == "p" }?[1]
            if let original, blocked.contains(original) { return true }
        }
        if let parentId = note.parentEventId, let parentAuthor = authorOf(parentId),
           blocked.contains(parentAuthor) {
            return true
        }
        return false
    }

    // MARK: - Feed Note Filtering

    /// Filters and sorts notes for the main feed based on mode and user preferences.
    ///
    /// - Parameters:
    ///   - notes: All notes currently in memory.
    ///   - mode: The active feed mode (following, discovery, global, popular, media).
    ///   - blocked: Hex pubkeys the user has blocked.
    ///   - showReposts: Whether kind-6 reposts should be visible.
    ///   - showReplies: Whether replies should be visible.
    ///   - followedPubkeys: Hex pubkeys the user follows.
    ///   - wotPubkeys: Web-of-Trust pubkey set (for global feed filtering).
    ///   - popularFilter: Sub-filter for the Popular feed (all / follows / non-follows).
    ///   - popularNoteScores: Popularity scores keyed by note ID (from the DVM).
    ///   - throttledPubkeys: Authors whose posts are rate-limited (pubkey -> max visible posts).
    /// - Returns: Filtered and sorted array of notes ready for display.
    static func filterFeedNotes(
        notes: [FeedNote],
        mode: FeedMode,
        articlesGlobal: Bool = false,
        blocked: Set<String>,
        showReposts: Bool,
        showReplies: Bool,
        followedPubkeys: [String],
        wotPubkeys: Set<String>,
        popularFilter: PopularFilter,
        popularNoteScores: [String: Double],
        throttledPubkeys: [String: Int],
        globalLanguages: Set<String> = [],
        globalRequiresTrust: Bool = true,
        languageOf: (FeedNote) -> String? = { _ in nil },
        authorOf: (String) -> String? = { _ in nil }
    ) -> [FeedNote] {
        // Articles: long-form only, one event per
        // `pubkey:d` address. 30023 is a parameterized-replaceable kind, so an
        // edited article arrives as a second event with the same address and
        // both would otherwise show as separate rows.
        if mode == .articles {
            let longForm = notes.filter { note in
                if involvesBlocked(note, blocked: blocked, authorOf: authorOf) { return false }
                guard note.kind == 30023 else { return false }
                // Global articles trust the same graph as Global, and fail
                // closed the same way; Following keeps to the follow set.
                if articlesGlobal {
                    return !globalRequiresTrust || wotPubkeys.contains(note.pubkey)
                }
                return followedPubkeys.contains(note.pubkey)
            }
            return dedupeAddressable(longForm)
        }

        var filtered = notes.filter { note in
            if involvesBlocked(note, blocked: blocked, authorOf: authorOf) { return false }
            if note.kind == 6 && !showReposts { return false }
            if mode == .popular {
                let isFollowed = followedPubkeys.contains(note.pubkey)
                if popularFilter == .follows && !isFollowed { return false }
                if popularFilter == .nonFollows && isFollowed { return false }
                return !note.isReply
            }
            if mode == .global {
                // Fail CLOSED. `wotPubkeys` empty used to mean "no trust data,
                // so admit everyone", which handed a brand-new account the open
                // firehose — measured at two thirds spam on the default seed
                // relays. An unusable graph now shows nothing and the caller
                // says so, rather than quietly showing the worst of Nostr.
                // The graph is seeded from the starter pack for an owner who
                // follows nobody, so empty here means "not built yet", not
                // "this user has no friends".
                // "Everyone" (opted into behind a warning) skips the graph.
                if globalRequiresTrust && !wotPubkeys.contains(note.pubkey) { return false }
                if note.isReply { return false }
                // Narrowed to chosen languages: notes whose language can't
                // be told (short, links only) stay. See FeedLanguageDetector.
                if globalLanguages.isEmpty { return true }
                return FeedLanguageDetector.admits(detected: languageOf(note), allowed: globalLanguages)
            }
            if mode == .following {
                // For reposts, membership is judged by the reposter (the follow
                // who boosted it), not the original author. The owner's own
                // pubkey is always in followedPubkeys (added by parseContactList),
                // so own posts remain visible. Excluding non-follows here makes an
                // unfollowed author's notes vanish the moment the set changes.
                let author = note.repostedBy ?? note.pubkey
                if !followedPubkeys.contains(author) { return false }
            }
            return showReplies || !note.isReply
        }

        // Popular feed: sort by engagement score instead of chronological
        if mode == .popular && !popularNoteScores.isEmpty {
            filtered.sort { a, b in
                let scoreA = popularNoteScores[a.id] ?? 0
                let scoreB = popularNoteScores[b.id] ?? 0
                if scoreA != scoreB { return scoreA > scoreB }
                return a.createdAt > b.createdAt
            }
        }

        // Apply per-author throttle limits
        if !throttledPubkeys.isEmpty {
            filtered = applyThrottleLimits(filtered, throttledPubkeys: throttledPubkeys)
        }

        return filtered
    }

    /// Filters notes for the media grid view.
    ///
    /// - Parameters:
    ///   - notes: All notes currently in memory.
    ///   - blocked: Hex pubkeys the user has blocked.
    ///   - wotPubkeys: Web-of-Trust pubkey set (for global media filtering).
    ///   - isGlobalMedia: Whether the media tab is in global mode.
    ///   - throttledPubkeys: Authors whose posts are rate-limited.
    /// - Returns: Notes containing media, sorted by date.
    static func filterMediaNotes(
        notes: [FeedNote],
        blocked: Set<String>,
        wotPubkeys: Set<String>,
        isGlobalMedia: Bool,
        globalRequiresTrust: Bool = true,
        throttledPubkeys: [String: Int],
        authorOf: (String) -> String? = { _ in nil }
    ) -> [FeedNote] {
        var media = notes.filter { note in
            if involvesBlocked(note, blocked: blocked, authorOf: authorOf) { return false }
            // Fail closed for the same reason as the Global feed above.
            if isGlobalMedia && globalRequiresTrust && !wotPubkeys.contains(note.pubkey) { return false }
            return !note.mediaURLs.isEmpty
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }

        if !throttledPubkeys.isEmpty {
            media = applyThrottleLimits(media, throttledPubkeys: throttledPubkeys)
        }

        return media
    }

    /// Collapses parameterized-replaceable events to one per `pubkey:d`
    /// address, keeping the newest, and returns them newest-first. Events with
    /// no `d` tag fall back to their own id so they are never merged together.
    static func dedupeAddressable(_ notes: [FeedNote]) -> [FeedNote] {
        var newestByAddress: [String: FeedNote] = [:]
        for note in notes {
            let dTag = note.tags.first { $0.count >= 2 && $0[0] == "d" }?[1]
            let address = "\(note.kind):\(note.pubkey):\(dTag ?? note.id)"
            if let existing = newestByAddress[address] {
                if note.createdAt > existing.createdAt { newestByAddress[address] = note }
            } else {
                newestByAddress[address] = note
            }
        }
        return newestByAddress.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    /// For each throttled author, keeps only their N most recent posts.
    private static func applyThrottleLimits(_ notes: [FeedNote], throttledPubkeys: [String: Int]) -> [FeedNote] {
        var authorCounts: [String: Int] = [:]
        return notes.filter { note in
            guard let maxPosts = throttledPubkeys[note.pubkey] else { return true }
            let count = authorCounts[note.pubkey, default: 0]
            if count < maxPosts {
                authorCounts[note.pubkey] = count + 1
                return true
            }
            return false
        }
    }

    /// Precomputes which notes have their parent as the immediately-next item
    /// in the filtered list. Used to collapse parent/child pairs in the UI.
    static func computeParentIsNext(filteredNotes: [FeedNote]) -> Set<String> {
        var result = Set<String>()
        for i in 0..<filteredNotes.count {
            if let parentId = filteredNotes[i].parentEventId,
               i + 1 < filteredNotes.count,
               filteredNotes[i + 1].id == parentId {
                result.insert(filteredNotes[i].id)
            }
        }
        return result
    }

    // MARK: - WoT Cache

    /// Loads Web-of-Trust pubkeys from the relay's cached `wot_cache.json` file.
    /// The relay computes this graph (owner -> follows -> follows-of-follows) and
    /// persists it to disk. Returns an empty set on any failure.
    /// Loads the Web-of-Trust graph the relay persisted to `wot_cache.json`.
    ///
    /// `ownerHex` is the active account. A graph whose only member is the owner
    /// carries no trust information — the relay seeds the graph with the owner
    /// and then adds who they follow, so an account with no follows produces a
    /// set of size one. Callers treat an empty set as "no trust data, do not
    /// filter"; returning the owner-only set instead made the Global feed
    /// filter every note by anyone else and render blank for every new user.
    /// Normalising it here keeps one definition of "unusable graph" for both
    /// the Global feed and the Global media grid.
    /// Returns `nil` when the cache could not be read at all — the caller keeps
    /// whatever graph it already had rather than throwing it away over a
    /// transient read failure. An empty set means the cache read fine and holds
    /// no usable graph, which the caller should apply (it clears a previous
    /// account's graph on a switch).
    static func loadWotPubkeys(from cacheURL: URL, ownerHex: String) -> Set<String>? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pubkeys = json["pubkeys"] as? [String: Bool] else {
            return nil
        }
        let loaded = Set(pubkeys.keys)
        guard hasUsableWot(loaded, ownerHex: ownerHex) else { return [] }
        return loaded
    }

    /// True when the graph names somebody other than the owner. An empty
    /// graph and a graph of just yourself are the same amount of evidence
    /// about who to trust: none.
    static func hasUsableWot(_ pubkeys: Set<String>, ownerHex: String) -> Bool {
        guard !pubkeys.isEmpty else { return false }
        if ownerHex.isEmpty { return true }
        return pubkeys.contains { $0 != ownerHex }
    }

    // MARK: - Relay URL Normalization

    /// Normalizes a relay URL string for deduplication (lowercased host, stripped
    /// trailing slash). Returns the lowercased input if parsing fails.
    static func normalizeRelayKey(_ urlStr: String) -> String? {
        guard let url = URL(string: urlStr), let host = url.host else { return urlStr.lowercased() }
        var key = "\(url.scheme ?? "wss")://\(host.lowercased())"
        if let port = url.port { key += ":\(port)" }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        if !path.isEmpty { key += path }
        return key
    }
}

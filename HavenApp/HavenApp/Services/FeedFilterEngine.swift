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
    /// Who may appear is the one gate's (`WebGate`): blocked people, muted
    /// words, hashtags and threads, and anyone outside the account's web never
    /// reach a feed through here. The mode then picks which of the rest it
    /// holds (follows only, never replies, and so on).
    ///
    /// - Parameters:
    ///   - notes: All notes currently in memory.
    ///   - mode: The active feed mode.
    ///   - gate: The open account's web, blocks and mutes (`FeedService.feedGate`).
    ///   - reach: How far this feed reaches (`FeedService.reach(for:)`).
    ///   - showReposts: Whether kind-6 reposts should be visible.
    ///   - showReplies: Whether replies should be visible.
    ///   - followedPubkeys: Hex pubkeys the user follows.
    ///   - popularFilter: Filter for popular feed (all, follows, non-follows).
    ///   - popularNoteScores: Note ID to engagement score mapping for popular sorting.
    /// - Returns: Filtered (and for popular mode, sorted) notes.
    static func filterFeedNotes(
        notes: [FeedNote],
        mode: FeedMode,
        articlesGlobal: Bool = false,
        pollsGlobal: Bool = false,
        pollStatus: PollStatusFilter = .all,
        now: Date = Date(),
        gate: WebGate.Web,
        reach: WebGate.Reach = .web,
        showReposts: Bool,
        showReplies: Bool,
        followedPubkeys: [String],
        ownPubkey: String = "",
        popularFilter: PopularFilter,
        popularNoteScores: [String: Double],
        globalLanguages: Set<String> = [],
        languageOf: (FeedNote) -> String? = { _ in nil },
        authorOf: (String) -> String? = { _ in nil }
    ) -> [FeedNote] {
        // A follow list runs to a thousand keys; checked per note as an
        // Array it was most of a rebuild's cost.
        let followedPubkeys = Set(followedPubkeys)
        func verdict(_ note: FeedNote) -> WebGate.Verdict {
            WebGate.judge(.feed(note, authorOf: authorOf), in: gate, reach: reach)
        }

        // Articles: long-form only, one event per
        // `pubkey:d` address. 30023 is a parameterized-replaceable kind, so an
        // edited article arrives as a second event with the same address and
        // both would otherwise show as separate rows.
        if mode == .articles {
            let longForm = notes.filter { note in
                guard note.kind == 30023 else { return false }
                let v = verdict(note)
                if v == .blocked { return false }
                // Global articles trust the same web as Global; Following
                // keeps to the follow set.
                if articlesGlobal { return v == .inside }
                return note.pubkey == ownPubkey || followedPubkeys.contains(note.pubkey)
            }
            return dedupeAddressable(longForm)
        }

        // Polls: NIP-88 polls only, newest first, scoped like Articles.
        if mode == .polls {
            return notes.filter { note in
                guard let poll = note.poll, pollStatus.admits(poll, now: now) else { return false }
                let v = verdict(note)
                if v == .blocked { return false }
                if pollsGlobal { return v == .inside }
                return note.pubkey == ownPubkey || followedPubkeys.contains(note.pubkey)
            }
        }

        var filtered = notes.filter { note in
            if note.kind == 6 && !showReposts { return false }
            let v = verdict(note)
            if v == .blocked { return false }
            // Judged on the signer: a repost's reposter, never the author its
            // content names (an unsigned claim).
            let author = note.repostedBy ?? note.pubkey
            switch mode {
            case .catchUp:
                // Your follows, as the relay picked them. Someone unfollowed
                // since it was computed goes now; an empty follow list shows
                // nobody rather than everyone.
                return followedPubkeys.contains(note.pubkey) && v == .inside
            case .underrated:
                // Top-level posts from people this account doesn't follow
                // (Logen 2026-11-06), in its web, or one hop out where its
                // reach allows (rationed below).
                return !note.isReply && note.pubkey != ownPubkey && !followedPubkeys.contains(note.pubkey)
                    && (v == .inside || v == .loose)
            case .popular:
                let isFollowed = followedPubkeys.contains(note.pubkey)
                if popularFilter == .follows && !isFollowed { return false }
                if popularFilter == .nonFollows && isFollowed { return false }
                return !note.isReply && v == .inside
            case .global:
                // Fail CLOSED: the gate's web is the follows alone until a
                // graph loads, never the open firehose. "Everyone" (behind a
                // warning) is reach `.everyone`.
                guard v == .inside, !note.isReply else { return false }
                // Narrowed to chosen languages: notes whose language can't
                // be told (short, links only) stay. See FeedLanguageDetector.
                if globalLanguages.isEmpty { return true }
                return FeedLanguageDetector.admits(detected: languageOf(note), allowed: globalLanguages)
            case .discovery:
                // The wider web minus your follows. The feed also pulls in
                // every note that tags you, so the gate drops anyone outside
                // the web (Android FeedFilterEngine.kt DISCOVERY).
                if followedPubkeys.contains(author) || v != .inside { return false }
            case .following:
                // Your own notes stay although your list need not follow you.
                // Excluding non-follows here makes an unfollowed author's notes
                // vanish the moment the set changes.
                if author != ownPubkey && !followedPubkeys.contains(author) { return false }
            default:
                // Every other list (Media, Reels, Music, Recipes, Live,
                // Marketplace, Hashtags) draws from the same notes, which
                // include notes tagging you from anyone: only the web's.
                if v != .inside { return false }
            }
            return showReplies || !note.isReply
        }

        // Local DVM feeds keep the relay's order: Popular and Underrated by
        // score, Catch Up newest first (its score is created_at).
        if mode.isLocalDvm && !popularNoteScores.isEmpty {
            filtered.sort { a, b in
                let scoreA = popularNoteScores[a.id] ?? 0
                let scoreB = popularNoteScores[b.id] ?? 0
                if scoreA != scoreB { return scoreA > scoreB }
                return a.createdAt > b.createdAt
            }
        }

        if reach == .webAndLoose {
            filtered = WebGate.capLoose(filtered, verdict: verdict, author: { $0.repostedBy ?? $0.pubkey },
                                       isReply: \.isReply)
        }
        return filtered
    }

    /// Filters notes for the media grid view.
    ///
    /// - Parameters:
    ///   - notes: All notes currently in memory.
    ///   - gate: The open account's web, blocks and mutes.
    ///   - reach: The Media feed's reach; `.everyone` for Global with the shield off.
    /// - Returns: Notes containing media from the web, sorted by date.
    static func filterMediaNotes(
        notes: [FeedNote],
        gate: WebGate.Web,
        reach: WebGate.Reach = .web,
        authorOf: (String) -> String? = { _ in nil }
    ) -> [FeedNote] {
        notes.filter { note in
            // Following and Global media alike: the notes tagging you from
            // anyone sit in the same list, so the gate judges every one.
            guard !note.mediaURLs.isEmpty else { return false }
            return WebGate.judge(.feed(note, authorOf: authorOf), in: gate, reach: reach) == .inside
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
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
        readWotCache(from: cacheURL, ownerHex: ownerHex)?.pubkeys
    }

    /// What `wot_cache.json` holds: the usable graph (as `loadWotPubkeys`)
    /// and the vouch counts, from one read and one parse. It was read and
    /// parsed twice, once for each. Safe off the main thread.
    struct WotCache {
        let pubkeys: Set<String>
        let vouches: [String: Int]?
        /// The depth the relay built at, nil from an older relay.
        var depth: Int? = nil
        /// `wot_links.json` beside the cache, read for a depth-3 web only
        /// (the relay deletes it at depth 2). The account web counts from it.
        var links: TrustLinksIndex? = nil
        /// The links file on disk was written for this cache (`WotFiles`).
        /// False in the moment between the relay's two writes.
        var linksCurrent = true
    }

    /// `readLinks: false` skips `wot_links.json` (several MB at depth 3), so
    /// a read on the main thread stays as cheap as it was; the caller parses
    /// the links off the main thread.
    static func readWotCache(from cacheURL: URL, ownerHex: String, readLinks: Bool = true) -> WotCache? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pubkeys = json["pubkeys"] as? [String: Bool] else {
            return nil
        }
        let loaded = Set(pubkeys.keys)
        let depth = json["depth"] as? Int
        let linksURL = WotFiles.linksURL(beside: cacheURL)
        let links = readLinks && (depth ?? 0) >= 3 ? (try? Data(contentsOf: linksURL)).flatMap(TrustLinksIndex.parse) : nil
        return WotCache(pubkeys: hasUsableWot(loaded, ownerHex: ownerHex) ? loaded : [],
                        vouches: TrustMap.vouches(fromJSON: json), depth: depth, links: links,
                        linksCurrent: WotFiles.linksCurrent(cacheURL: cacheURL, depth: depth))
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

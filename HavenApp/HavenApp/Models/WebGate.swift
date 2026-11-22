import Foundation

/// The one rule for who may put words in front of an account (Logen
/// 2026-11-18): every feed, mention, notification, Vault list, thread and
/// chat asks this gate, and none checks the web, the block list or the mute
/// list on its own. Android's `WebGate.kt` is the same rule, line for line.
///
/// The rule, first match wins:
/// 1. **blocked**: the signer or anyone else the row shows is blocked, or the
///    mute list hides the note (word, hashtag, thread). Your own accounts are
///    never blocked as people; mutes on words, hashtags and threads still
///    apply to them.
/// 2. **inside**: the signer is one of your accounts or a key the surface
///    always shows.
/// 2a. **outside** (or inside on reach `everyone`): the signer's secret key
///    is public (`PublicKeyRegistry`), whatever the web or whitelist says.
/// 2b. **inside**: the whitelist or your own web.
/// 3. **inside** again when the surface's reach is `everyone` (a Global feed
///    with the shield on Everyone).
/// 4. **loose**: reach is `webAndLoose` and the signer is one hop past your web.
/// 5. **outside**: everyone else.
///
/// It fails closed: with no graph, the web is your follows and nothing is one
/// hop out (`Web.build`). The relay's pooled web (every account on the device)
/// never judges one account.
enum WebGate {
    enum Verdict: String, Equatable, Sendable {
        case inside, loose, outside, blocked
    }

    /// How far a surface reaches. Only a feed has a setting; every other
    /// surface is `web`.
    enum Reach: String, Codable, CaseIterable, Sendable {
        case web
        /// Your web plus a few one hop past it, rationed by `capLoose`.
        /// The raw value is the word saved in `HavenConfig.feedReach`: it
        /// stays "webAndHop3" whatever the case is called, or every saved
        /// Reach choice falls back to its default.
        case webAndLoose = "webAndHop3"
        /// A Global-style feed with the shield on Everyone. Blocks still apply.
        case everyone
    }

    /// One account's web, built once and read for every note. Keys are
    /// lowercased hex.
    struct Web: Equatable, Sendable {
        /// Every account on this device, the one being judged for included.
        var own: Set<String>
        var whitelist: Set<String>
        /// Follows, plus (at depth 3) anyone Min Followers of the follows follow.
        var web: Set<String>
        /// One hop past `web`: followed by some of the follows, fewer than the
        /// bar (depth 3), or in the relay's saved web but not this account's
        /// (depth 2). Empty with no graph.
        var loose: Set<String>
        /// Public blocks and the mute list's private people.
        var blocked: Set<String>
        var mutes: MuteList

        init(own: Set<String>, whitelist: Set<String> = [], web: Set<String>, loose: Set<String> = [],
             blocked: Set<String> = [], mutes: MuteList = .empty) {
            self.own = WebGate.lowered(own)
            self.whitelist = WebGate.lowered(whitelist)
            self.web = WebGate.lowered(web)
            self.loose = WebGate.lowered(loose).subtracting(self.web)
            self.blocked = WebGate.lowered(blocked.union(mutes.privatePubkeys))
            self.mutes = mutes
        }

        /// The web of the account `scope` describes, from the relay's saved
        /// graph and links. Unlike `AccountWeb.web` it never falls back to
        /// the pooled web: no graph, or a follow list not yet confirmed, is
        /// just the follows.
        static func build(saved: Set<String>, follows: Set<String>, links: TrustLinksIndex?, depth: Int?,
                          scope: AccountWebScope, whitelist: Set<String> = [],
                          blocked: Set<String> = [], mutes: MuteList = .empty) -> Web {
            let layers = WebGate.layers(saved: saved, follows: follows, links: links, depth: depth, scope: scope)
            return Web(own: scope.owners, whitelist: whitelist, web: layers.web, loose: layers.loose,
                       blocked: blocked, mutes: mutes)
        }
    }

    /// What is judged: who signed it, who else the row shows, and the note
    /// itself for the mute list.
    struct Subject: Equatable, Sendable {
        /// The signer: a repost's reposter; a zap's verified request signer.
        /// Empty when nobody can be named (an unverified zap): never inside.
        var signer: String
        /// Everyone else the row puts in front of you, only checked for blocks:
        /// a repost's original author, the parent's author, a stream's host.
        var related: [String]
        var id: String
        var parentId: String?
        var content: String
        var tags: [[String]]
        /// Other notes the row stands for, checked against muted threads only:
        /// the post a repost shows.
        var otherIds: [String]

        init(signer: String, related: [String] = [], id: String = "", parentId: String? = nil,
             content: String = "", tags: [[String]] = [], otherIds: [String] = []) {
            self.signer = signer
            self.related = related
            self.id = id
            self.parentId = parentId
            self.content = content
            self.tags = tags
            self.otherIds = otherIds
        }

        /// A note as a row shows it, the one way every surface builds one so
        /// none can drift (Tron, #2213). A repost is the reposter's row: the
        /// reposter signs, the original author is only checked for blocks,
        /// and the mute list reads the post shown (its text, tags and id).
        /// - Parameters:
        ///   - author: who wrote the text shown (a repost's original author).
        ///   - repostedBy: the reposter, for a repost.
        ///   - originalId: the post a repost shows, when the row is a repost.
        ///   - parentAuthor: the author of the note a reply answers, if known.
        static func note(id: String, author: String, content: String, tags: [[String]],
                         parentId: String? = nil, repostedBy: String? = nil, originalId: String? = nil,
                         parentAuthor: String? = nil) -> Subject {
            let signer = repostedBy ?? author
            var related: [String] = []
            if author != signer, !author.isEmpty { related.append(author) }
            if let parentAuthor, !parentAuthor.isEmpty { related.append(parentAuthor) }
            return Subject(signer: signer, related: related, id: id, parentId: parentId,
                           content: content, tags: tags, otherIds: originalId.map { [$0] } ?? [])
        }

        /// A zap is judged on the zap request's signer, and only when that
        /// request's signature checked out. The receipt's own signer is the
        /// lightning service, never a person.
        static func zap(requestSigner: String?, verified: Bool, receiptId: String = "",
                        comment: String = "", related: [String] = []) -> Subject {
            Subject(signer: verified ? (requestSigner ?? "") : "", related: related,
                    id: receiptId, content: comment)
        }
    }

    static func judge(_ subject: Subject, in web: Web, reach: Reach = .web,
                      always: Set<String> = []) -> Verdict {
        let signer = subject.signer.lowercased()
        if isBlocked(subject, signer: signer, in: web) { return .blocked }
        guard !signer.isEmpty else { return .outside }
        if web.own.contains(signer) || lowered(always).contains(signer) { return .inside }
        // A key anyone can post with (its nsec sits in a profile we loaded,
        // PublicKeyRegistry) is no longer the person you trusted: outside your
        // web and past hop 3, as a stranger is.
        if PublicKeyRegistry.shared.isPublic(signer) { return reach == .everyone ? .inside : .outside }
        if web.whitelist.contains(signer) || web.web.contains(signer) { return .inside }
        switch reach {
        case .everyone: return .inside
        case .webAndLoose where web.loose.contains(signer): return .loose
        default: return .outside
        }
    }

    /// Step 1 alone, for a surface that only hides (a quote card, a DM row).
    static func isBlocked(_ subject: Subject, in web: Web) -> Bool {
        isBlocked(subject, signer: subject.signer.lowercased(), in: web)
    }

    private static func isBlocked(_ subject: Subject, signer: String, in web: Web) -> Bool {
        if !web.blocked.isEmpty {
            for key in [signer] + subject.related.map({ $0.lowercased() })
            where !key.isEmpty && !web.own.contains(key) && web.blocked.contains(key) {
                return true
            }
        }
        if web.mutes.hides(id: subject.id, content: subject.content, tags: subject.tags,
                           parentId: subject.parentId) {
            return true
        }
        return !web.mutes.threads.isEmpty
            && subject.otherIds.contains { web.mutes.threads.contains($0.lowercased()) }
    }

    // MARK: - Hop 3, rationed

    /// Most hop-3 rows one list shows: a fifth of its other rows, and never
    /// fewer than this, so a feed made mostly of them (Underrated on a
    /// phone, whose web is its follows) still shows a few.
    static let looseFloor = 10
    static let looseShare = 5

    /// `items` with the hop-3 rows rationed, order kept: top-level posts only
    /// (a hop-3 reply goes), one per author, and at most
    /// max(`looseFloor`, other rows / `looseShare`). Rows past the ration are
    /// left out, not folded: they were not refused, only rationed. Other
    /// verdicts pass through untouched; the caller has already folded or
    /// dropped them.
    static func capLoose<T>(_ items: [T], verdict: (T) -> Verdict, author: (T) -> String,
                           isReply: (T) -> Bool) -> [T] {
        let verdicts = items.map(verdict)
        let others = verdicts.filter { $0 != .loose }.count
        let cap = max(looseFloor, others / looseShare)
        var shown = 0
        var authors = Set<String>()
        var out: [T] = []
        out.reserveCapacity(items.count)
        for (item, v) in zip(items, verdicts) {
            guard v == .loose else { out.append(item); continue }
            guard shown < cap, !isReply(item), authors.insert(author(item).lowercased()).inserted else { continue }
            shown += 1
            out.append(item)
        }
        return out
    }

    // MARK: - Layers

    /// The account's web and the hop past it, from the relay's files
    /// (`wot_cache.json`, `wot_links.json`). Fails closed: no graph, or the
    /// follow list not yet known, is the follows alone with no hop 3; a depth
    /// or links file it cannot read is the follows, with the saved web as
    /// hop 3.
    static func layers(saved: Set<String>, follows: Set<String>, links: TrustLinksIndex?, depth: Int?,
                       scope: AccountWebScope) -> (web: Set<String>, loose: Set<String>) {
        var web = follows.union(scope.owners)
        guard !saved.isEmpty, scope.followsKnown else { return (web, []) }
        guard depth == 3, let links else { return (web, saved.subtracting(web)) }
        let bar = max(scope.minFollowers, 1)
        let counts = AccountWeb.vouchCounts(links: links, follows: follows, excluding: web)
        if follows.count < bar {
            // A new account's web is widened like the relay's newAccountWeb.
            let ranked = AccountWeb.widened(counts)
            web.formUnion(ranked.prefix(AccountWeb.newAccountWebCap))
            return (web, Set(ranked.dropFirst(AccountWeb.newAccountWebCap)))
        }
        var loose = Set<String>()
        for (pubkey, counted) in counts {
            if counted >= bar { web.insert(pubkey) } else { loose.insert(pubkey) }
        }
        return (web, loose)
    }

    fileprivate static func lowered(_ keys: Set<String>) -> Set<String> {
        // Most keys arrive lowercase already: skip the copy when they all do.
        guard keys.contains(where: { $0.utf8.contains { $0 >= 65 && $0 <= 90 } }) else { return keys.subtracting([""]) }
        return Set(keys.map { $0.lowercased() }).subtracting([""])
    }
}

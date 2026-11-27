import Foundation

/// The one order every box that finds a person uses (search plan §1a,
/// Logen go 5d1ce4cb): the Search tab, the WoT globe's Find someone, the
/// Vault's People, mentions and the message pickers. Pure, so
/// MediaLogicTests compiles this same file. Android twin:
/// `data/model/PeopleSearchRank.kt`; web: `net/people-rank.js`.
///
/// Sort key, lowest first:
/// 1. **Closeness:** -1 in this thread (mentions only) · 0 you · 1 follows ·
///    2 your web · 3 further out (3+ steps, from the Haven's rank copy) ·
///    4 outside. 3+ steps counts as inside your web (Logen 5d1ce4cb #6).
/// 2. **Name match:** exact > starts with > a word starts with > contains >
///    about only, on the display name, name and NIP-05, case and accents
///    folded.
/// 3. **Trust score** from the rank copy, high first.
/// 4. Shorter name, then pubkey, so the order holds while results stream in.
///
/// Blocked people are always dropped. No follower or engagement counts: they
/// are cheap to fake.
enum PeopleSearchRank {

    /// Who is how close to you.
    struct Circle {
        var own: Set<String>
        var follows: Set<String>
        /// Your web: follows of follows and the relay's WoT graph.
        var web: Set<String>
        /// The Haven's rank copy: hops 2+ and trust scores. nil without a Haven.
        var copy: TrustRankCopy?
        /// The people in the thread being replied to; only mentions set it.
        var thread: Set<String> = []

        init(own: Set<String>, follows: Set<String>, web: Set<String>,
             copy: TrustRankCopy? = nil, thread: Set<String> = []) {
            self.own = Set(own.map { $0.lowercased() })
            self.follows = follows
            self.web = web
            self.copy = copy
            self.thread = thread
        }

        func score(_ pubkey: String) -> Double { copy?[pubkey]?.score ?? 0 }
    }

    enum Tier {
        static let thread = -1
        static let you = 0
        static let follow = 1
        static let web = 2
        static let further = 3
        static let outside = 4
    }

    /// Someone a box found: their key and what they go by.
    struct Person: Equatable {
        let pubkey: String
        var displayName: String?
        var name: String?
        var nip05: String?
        var about: String?

        init(pubkey: String, displayName: String? = nil, name: String? = nil,
             nip05: String? = nil, about: String? = nil) {
            self.pubkey = pubkey
            self.displayName = displayName
            self.name = name
            self.nip05 = nip05
            self.about = about
        }

        /// The names a match is judged on; NIP-05 also by its part before the
        /// `@` (none for `_@`, which stands for the domain).
        var names: [String] {
            var out = [displayName, name].compactMap { $0 }.filter { !$0.isEmpty }
            if let nip05, !nip05.isEmpty {
                out.append(nip05)
                if let at = nip05.firstIndex(of: "@") {
                    let local = String(nip05[..<at])
                    if !local.isEmpty, local != "_" { out.append(local) }
                }
            }
            return out
        }
    }

    /// A cached profile as the ranker sees it.
    static func person(_ profile: FeedProfile) -> Person {
        Person(pubkey: profile.pubkey, displayName: profile.displayName, name: profile.name,
               nip05: profile.nip05, about: profile.about)
    }

    static func tier(_ pubkey: String, in circle: Circle) -> Int {
        let key = pubkey.lowercased()
        if circle.thread.contains(pubkey) || circle.thread.contains(key) { return Tier.thread }
        if circle.own.contains(key) { return Tier.you }
        if circle.follows.contains(pubkey) || circle.follows.contains(key) { return Tier.follow }
        if circle.web.contains(pubkey) || circle.web.contains(key) { return Tier.web }
        if let hop = circle.copy?[key]?.hop {
            return hop <= 2 ? Tier.web : Tier.further
        }
        return Tier.outside
    }

    /// Inside your web: you, follows, your web and people 3+ steps away.
    /// The rest folds under "N from outside your web" — even an exact name
    /// (Logen 5d1ce4cb #1).
    static func isInside(_ pubkey: String, in circle: Circle) -> Bool {
        tier(pubkey, in: circle) < Tier.outside
    }

    // MARK: Name match

    enum Match {
        static let exact = 0
        static let prefix = 1
        static let wordPrefix = 2
        static let contains = 3
        static let aboutOnly = 4
        /// A source matched on something we cannot see (a search relay's
        /// own index); kept last when the box keeps every answer.
        static let unseen = 5
    }

    /// Case-, accent- and width-folded, trimmed. "Zoë" and "zoe" are the same.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How well `person` matches the folded query; nil for no match at all.
    static func match(_ folded: String, _ person: Person) -> Int? {
        guard !folded.isEmpty else { return nil }
        var best: Int?
        for raw in person.names {
            let name = fold(raw)
            let m: Int?
            if name == folded {
                m = Match.exact
            } else if name.hasPrefix(folded) {
                m = Match.prefix
            } else if words(of: name).contains(where: { $0.hasPrefix(folded) }) {
                m = Match.wordPrefix
            } else if name.contains(folded) {
                m = Match.contains
            } else {
                m = nil
            }
            if let m, m < (best ?? Int.max) { best = m }
            if best == Match.exact { break }
        }
        if best == nil, let about = person.about, fold(about).contains(folded) { best = Match.aboutOnly }
        return best
    }

    private static func words(of name: String) -> [Substring] {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// The shortest name, for the tie-break; people with no name sort after.
    private static func length(_ person: Person) -> Int {
        person.names.map(\.count).min() ?? Int.max
    }

    // MARK: Ranking

    /// `items` in rank order, blocked people dropped, each pubkey once.
    /// - keepUnmatched: keep people the query does not match in any field
    ///   we hold (a search relay matched them on its own index), last in
    ///   their tier. Boxes that match locally leave it off and drop them.
    static func rank<T>(_ items: [T], query: String, circle: Circle,
                        blocked: Set<String> = [], keepUnmatched: Bool = false,
                        limit: Int? = nil, person: (T) -> Person) -> [T] {
        let folded = fold(query)
        var seen = Set<String>()
        var keyed: [(item: T, tier: Int, match: Int, score: Double, length: Int, key: String)] = []
        for item in items {
            let p = person(item)
            let key = p.pubkey.lowercased()
            guard !blocked.contains(p.pubkey), !blocked.contains(key), seen.insert(key).inserted else { continue }
            let found = match(folded, p)
            guard found != nil || keepUnmatched else { continue }
            keyed.append((item, tier(p.pubkey, in: circle), found ?? Match.unseen,
                          circle.score(key), length(p), key))
        }
        keyed.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.match != b.match { return a.match < b.match }
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.key < b.key
        }
        let ranked = keyed.map(\.item)
        return limit.map { Array(ranked.prefix($0)) } ?? ranked
    }

    /// Ranked, then split by your web: inside first, the rest for the fold.
    /// Order holds on both sides.
    static func split<T>(_ items: [T], query: String, circle: Circle,
                         blocked: Set<String> = [], keepUnmatched: Bool = false,
                         person: (T) -> Person) -> (inside: [T], outside: [T]) {
        var inside: [T] = [], outside: [T] = []
        for item in rank(items, query: query, circle: circle, blocked: blocked,
                         keepUnmatched: keepUnmatched, person: person) {
            if isInside(person(item).pubkey, in: circle) { inside.append(item) } else { outside.append(item) }
        }
        return (inside, outside)
    }

    /// The fold may open by itself when the only exact name match is in it
    /// (Logen 5d1ce4cb #1): it is who you were looking for.
    static func outsideHoldsTheOnlyExactMatch<T>(inside: [T], outside: [T], query: String,
                                                 person: (T) -> Person) -> Bool {
        let folded = fold(query)
        return !inside.contains(where: { match(folded, person($0)) == Match.exact })
            && outside.contains(where: { match(folded, person($0)) == Match.exact })
    }
}

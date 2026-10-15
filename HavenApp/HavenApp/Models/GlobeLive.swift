import Foundation

/// What flies on the globe, by sort, and how hard a zap strikes: the My Web
/// dashboard's Live arrivals switches beyond the three feeds.
extension GlobeArcs {
    /// What an arrival is.
    enum Sort: String, CaseIterable {
        /// A new note, or a quote.
        case note
        case reply
        case repost
        /// A kind 7 reaction: a smaller star.
        case reaction
        case zap
    }

    /// Which sorts fly. All on unless switched off.
    struct Show: Hashable {
        var notes = true
        var replies = true
        var reposts = true
        var reactions = true
        var zaps = true

        func allows(_ sort: Sort) -> Bool {
            switch sort {
            case .note: notes
            case .reply: replies
            case .repost: reposts
            case .reaction: reactions
            case .zap: zaps
            }
        }

        /// The kinds to ask relays for by author or for you: notes and
        /// replies are both kind 1 (and 1111), so either keeps them.
        var noteKinds: [Int] {
            (notes || replies ? GlobeArcs.kinds : []) + (reactions ? [GlobeArcs.reactionKind] : [])
        }

        /// The wide REQ's kinds: the notes' and, with Reposts on, reposts.
        var wideKinds: [Int] { noteKinds + (reposts ? GlobeArcs.repostKinds : []) }
    }

    /// NIP-25 reactions (likes, emoji).
    static let reactionKind = 7

    /// A reaction flies from the reactor to the person reacted to: NIP-25's
    /// last `p` tag, beside the `e` of the note it reacts to. Like a reply
    /// we can't place, one without that person (or reacting to themself)
    /// doesn't fly, so it never lands on you by default.
    static func reaction(id: String, author: String, tags: [[String]]) -> Arrival? {
        guard tags.contains(where: { $0.count >= 2 && $0[0] == "e" }),
              let to = tags.last(where: { $0.count >= 2 && $0[0] == "p" })?[1].lowercased(),
              isKey(to), to != author else { return nil }
        return Arrival(id: id, author: author, targets: [to], sort: .reaction)
    }

    /// How hard a zap's bolt strikes, 0.15 to 1, by sats on a log scale:
    /// 21 sats a light flick, 1,000 a solid strike, 100,000 and up the most.
    /// A zap whose amount isn't known strikes lightly.
    static func zapStrength(sats: Int) -> Double {
        guard sats > 1 else { return 0.15 }
        return min(1, max(0.15, log10(Double(sats)) / 5))
    }
}

/// Whether notes fly across the WOT globe as they reach the relay, and from
/// which feeds. Kept across launches, like Auto-load. The bar's antenna is
/// the main switch; the My Web dashboard picks the feeds.
enum LiveArcsSetting {
    static let key = "wotLiveArcs"
    /// Live arrivals start on (Logen, 10/15). The switch is only stored once
    /// someone flips it, so a new install and anyone who never touched it
    /// get on, and anyone who turned it off keeps it off.
    static let defaultOn = true

    /// Each feed's own switch. All three start on.
    static func key(_ ring: GlobeArcs.Ring) -> String {
        "wotLiveArcs." + ring.rawValue
    }

    /// Each sort's own switch (new notes, replies, reposts, reactions,
    /// zaps). All on.
    static func key(_ sort: GlobeArcs.Sort) -> String {
        "wotLiveArcs.sort." + sort.rawValue
    }

    /// The globe's idle spin. On.
    static let spinKey = "wotGlobeSpin"

    /// The antenna as `@AppStorage(key) … = defaultOn` reads it.
    static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultOn
    }
}

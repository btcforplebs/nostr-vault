import Foundation

/// What flies on the globe, by sort, and how hard a zap strikes: the My Web
/// dashboard's switches beside Live stars.
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

    /// The My Web switches beyond Live stars itself: friends of friends,
    /// and the small stuff (likes, reposts and zaps). Both on unless
    /// switched off.
    struct Show: Hashable {
        /// Friends of friends (hop 2) fly; off, only your follows do.
        var friends = true
        /// Likes, reposts and zaps fly; off, only notes and replies do.
        var extras = true

        func allows(_ sort: Sort) -> Bool {
            switch sort {
            case .note, .reply: true
            case .repost, .reaction, .zap: extras
            }
        }

        /// The kinds asked for by author: notes and replies, and with the
        /// small stuff on, reactions and reposts.
        var authorKinds: [Int] {
            GlobeArcs.kinds + (extras ? [GlobeArcs.reactionKind] + GlobeArcs.repostKinds : [])
        }
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

/// Live stars on the WOT globe and the two switches beside it in My Web
/// (on the Mac, in the bar's antenna menu). Kept across launches. All three
/// start on, and are stored only once someone flips them.
enum LiveArcsSetting {
    /// Live stars, also the bar's antenna.
    static let key = "wotLiveArcs"
    static let defaultOn = true
    /// Friends of friends (hop 2).
    static let friendsKey = "wotStars.friends"
    /// Likes, reposts and zaps.
    static let extrasKey = "wotStars.extras"

    /// The feed, sort and spin switches My Web had until 11/12, when Logen had
    /// them cut. A value someone stored would have no switch left to undo it,
    /// so it goes. Neither the antenna (`key`) nor today's switches are among them.
    static let retiredKeys = [
        "wotLiveArcs.following", "wotLiveArcs.discover", "wotLiveArcs.global",
        "wotLiveArcs.sort.note", "wotLiveArcs.sort.reply", "wotLiveArcs.sort.repost",
        "wotLiveArcs.sort.reaction", "wotLiveArcs.sort.zap", "wotGlobeSpin",
    ]

    static func retireCutSwitches(_ defaults: UserDefaults = .standard) {
        for retired in retiredKeys { defaults.removeObject(forKey: retired) }
    }

    /// The antenna as `@AppStorage(key) … = defaultOn` reads it.
    static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultOn
    }
}

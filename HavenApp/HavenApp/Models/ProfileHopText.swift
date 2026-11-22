import Foundation

/// The line under a profile's name: how far they are from you, in true hops
/// at any distance (Logen 2026-11-22: "4 hops" for someone far out, up to 6),
/// and who you follow follows them. Android twin:
/// `data/model/ProfileHopText.kt`.
///
/// - "1 hop · you follow them"
/// - "2 hops · followed by Alice, Bob and 3 more"
/// - "4 hops"
///
/// The hop comes from your follows and the people you follow (the Trust
/// Path), and past that from your Haven's rank (`TrustRankCopy`). With
/// neither, there is no line: nothing claims a distance it does not know.
enum ProfileHopText {
    /// Names shown before "and N more".
    static let named = 2

    /// The hop to show. Rings 1 and 2 come from your follows and the Trust
    /// Path, which follow an unfollow at once; the Haven's copy can be a day
    /// old (Tron, #2419), so it only places people further out, and ring 2
    /// only when the path cannot say (no names then). nil for you, for
    /// someone the path finds outside your web, and for anyone neither knows.
    static func hop(pubkey: String, me: String, path: TrustPath?, rank: TrustRankCopy.Person?) -> Int? {
        if pubkey.caseInsensitiveCompare(me) == .orderedSame { return nil }
        let far = { (min: Int) -> Int? in rank.flatMap { $0.hop >= min ? $0.hop : nil } }
        switch path?.reach {
        case .you: return nil
        case .follow: return 1
        case .bridged: return 2
        case .outside: return far(3)
        case .web, .unknown, nil: return far(2)
        }
    }

    static func line(pubkey: String, me: String, path: TrustPath?, rank: TrustRankCopy.Person?,
                     name: (String) -> String) -> String? {
        guard let hop = hop(pubkey: pubkey, me: me, path: path, rank: rank) else { return nil }
        if hop == 1 { return "1 hop · you follow them" }
        let followedBy = path.flatMap { $0.reach == .bridged ? Self.followedBy($0, name: name) : nil }
        return followedBy.map { "\(hop) hops · \($0)" } ?? "\(hop) hops"
    }

    /// "followed by Alice, Bob and 3 more". The number only when the path
    /// knows every bridge (`TrustPath.complete`, the links file); from relays
    /// it says "and more", since their count is only a floor.
    static func followedBy(_ path: TrustPath, name: (String) -> String) -> String? {
        let all = path.all.isEmpty ? path.bridges : path.all
        guard !all.isEmpty else { return nil }
        let names = all.prefix(named).map(name)
        let rest = all.count - names.count
        let who: String
        if rest > 0 && path.complete {
            who = names.joined(separator: ", ") + " and \(rest) more"
        } else if rest > 0 || path.hasMore {
            who = names.joined(separator: ", ") + " and more"
        } else {
            who = names.joined(separator: " and ")
        }
        return "followed by " + who
    }
}

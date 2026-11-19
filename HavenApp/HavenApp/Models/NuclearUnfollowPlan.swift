import Foundation

/// Nuclear unfollow, as rules (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md, Logen
/// 2026-11-19): cut person X and everyone you follow who follows X, in one
/// new follow list built from the newest one, every other tag and the
/// content kept as they are.
enum NuclearUnfollowPlan {
    /// At this many people a second warning follows the first.
    static let doubleWarnAt = 25

    /// Who goes: the people left checked, and X when you follow them.
    static func removal(checked: Set<String>, target: String, follows: Set<String>) -> Set<String> {
        var out = Set(checked.map { $0.lowercased() })
        let x = target.lowercased()
        if follows.contains(where: { $0.lowercased() == x }) { out.insert(x) }
        return out
    }

    static func needsSecondWarning(_ count: Int) -> Bool { count >= doubleWarnAt }

    enum Build: Equatable {
        case ready(tags: [[String]])
        /// Nobody in the list is going: nothing to publish.
        case unchanged
        case refuse(String)
    }

    /// The new list's tags: `base` with the `p` tags of `removing` left out.
    /// Nothing else moves. Refused when there is no list to start from, or
    /// when it would leave no one followed at all.
    static func newTags(base: [[String]]?, removing: Set<String>) -> Build {
        guard let base else {
            return .refuse("Your follow list couldn't be found, so nothing was changed.")
        }
        let gone = Set(removing.map { $0.lowercased() })
        let isFollowTag: ([String]) -> Bool = { $0.count >= 2 && $0[0] == "p" }
        let kept = base.filter { !(isFollowTag($0) && gone.contains($0[1].lowercased())) }
        guard kept.count < base.count else { return .unchanged }
        let before = base.filter(isFollowTag).count
        if before > 0, !kept.contains(where: isFollowTag) {
            return .refuse("That would leave you following no one, so nothing was changed.")
        }
        return .ready(tags: kept)
    }

    /// "Unfollow 1 person" / "Unfollow 30 people".
    static func confirmTitle(_ count: Int) -> String {
        count == 1 ? "Unfollow 1 person" : "Unfollow \(count) people"
    }
}

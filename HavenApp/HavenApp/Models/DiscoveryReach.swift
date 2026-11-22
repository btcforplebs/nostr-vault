import Foundation

/// Settings › Feeds › Discovery reach: the slider over the desktop Vault's
/// trust rank (`TrustRankCopy`). People ranked at or over the bar are let
/// into the discovery feeds even when they are past your web. Only
/// Underrated and Discovery read it; notifications, replies and every other
/// feed keep to your web (plan phase 4, Logen 2026-11-22).
///
/// With no rank file there is no slider and nothing changes: a phone gets
/// scores only from a desktop Vault.
enum DiscoveryReach {
    /// The feeds the slider widens.
    static let modes: Set<FeedMode> = [.underrated, .discovery]

    /// Rings 1-2 are your circle; 3 and out are distant connections.
    static let circleHops = 2

    /// The bar in use: the saved one, else the file's starting bar, kept
    /// between the file's floor (people under it never reached the phone)
    /// and 100, in whole steps. A saved bar outside 0-100 reads as unset.
    static func bar(saved: Double?, copy: TrustRankCopy) -> Double {
        let low = copy.floor.rounded(.up)
        let wanted = saved.flatMap { (0...100).contains($0) ? $0 : nil } ?? copy.viewBar
        return min(100, max(low, wanted.rounded()))
    }

    /// The slider's range for `copy`.
    static func range(_ copy: TrustRankCopy) -> ClosedRange<Double> {
        min(copy.floor.rounded(.up), 100)...100
    }

    /// Who the bar lets in past your follows: everyone two or more hops out
    /// scored at or over `bar`. Keys are lowercase hex (the file's own).
    static func admitted(_ copy: TrustRankCopy, bar: Double) -> Set<String> {
        var out = Set<String>()
        for (pubkey, person) in copy.people where person.hop >= 2 && person.score >= bar {
            out.insert(pubkey)
        }
        return out
    }

    struct Count: Equatable {
        /// Two hops out: followed by people you follow.
        var circle: Int
        /// Three hops out and further.
        var distant: Int
    }

    /// How many people `bar` lets in, for the live line under the slider.
    static func count(_ copy: TrustRankCopy, bar: Double) -> Count {
        var count = Count(circle: 0, distant: 0)
        for person in copy.people.values where person.hop >= 2 && person.score >= bar {
            if person.hop <= circleHops { count.circle += 1 } else { count.distant += 1 }
        }
        return count
    }

    /// "1,204 people in your circle and 87 distant connections".
    static func countText(_ count: Count) -> String {
        let circle = count.circle.formatted()
        let distant = count.distant.formatted()
        let people = count.circle == 1 ? "person" : "people"
        let connections = count.distant == 1 ? "distant connection" : "distant connections"
        return "\(circle) \(people) in your circle and \(distant) \(connections)"
    }

    /// The saved value for `bar`: nil when it is the file's starting bar,
    /// so a later file with a new starting bar still moves it.
    static func saved(_ bar: Double, copy: TrustRankCopy) -> Double? {
        bar == Self.bar(saved: nil, copy: copy) ? nil : bar
    }
}

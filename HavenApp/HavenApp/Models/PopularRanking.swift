import Foundation

/// Numbers for the Popular feed's rank line.
enum PopularRanking {
    /// Each scored post's place in the feed as shown, from #1. `ids` is the
    /// shown order, which the filter already sorted by score, so the rank is
    /// the position among scored posts. Replies threaded under a post have no
    /// score and take no number, and a narrower audience renumbers from #1.
    /// Equal scores get consecutive numbers in the shown order.
    static func ranks(ids: [String], scores: [String: Double]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for id in ids where scores[id] != nil && ranks[id] == nil {
            ranks[id] = ranks.count + 1
        }
        return ranks
    }
}

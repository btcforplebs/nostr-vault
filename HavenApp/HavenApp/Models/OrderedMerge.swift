import Foundation

/// Adds a batch to a list that is kept in order, without re-sorting the whole
/// list. The feed flush re-sorted up to 10,000 notes on the main thread for
/// every batch, 20 times a second in Global (Mac sweep 11-01 #3).
///
/// Kept free of app types so `MediaLogicTests` can compile it.
enum OrderedMerge {
    /// `sorted` plus `batch`, ordered by `areInOrder` (true when the first
    /// belongs before the second). The same result as sorting the two
    /// together: when `sorted` turns out not to be in order (a feed filled
    /// by score, a post put on top by hand) it falls back to a full sort.
    static func inserting<T>(_ batch: [T], into sorted: [T], by areInOrder: (T, T) -> Bool) -> [T] {
        guard !batch.isEmpty else { return sorted }
        let isSorted = zip(sorted, sorted.dropFirst()).allSatisfy { !areInOrder($1, $0) }
        guard isSorted else { return (sorted + batch).sorted(by: areInOrder) }
        let incoming = batch.sorted(by: areInOrder)
        var merged: [T] = []
        merged.reserveCapacity(sorted.count + incoming.count)
        var i = 0, j = 0
        while i < sorted.count, j < incoming.count {
            if areInOrder(incoming[j], sorted[i]) {
                merged.append(incoming[j]); j += 1
            } else {
                merged.append(sorted[i]); i += 1
            }
        }
        merged.append(contentsOf: sorted[i...])
        merged.append(contentsOf: incoming[j...])
        return merged
    }
}

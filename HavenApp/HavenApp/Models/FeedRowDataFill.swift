import Foundation

/// The feed's row-data cache after the shown notes change, without resolving
/// rows nobody has looked at.
///
/// A row gets its data the first time it is drawn (`FeedRowDrafts`), and
/// `reconcile` then files those drawn rows in the cache. A row that was never
/// drawn stays out and resolves when it scrolls in. Before this, the reconcile
/// after a feed switch resolved every note of the new feed on the main thread,
/// hundreds of them, and the rows on screen a second time.
enum FeedRowDataFill {
    /// The cache for `notes`: a cached or drawn row is kept, and resolved
    /// again only when `needsRepair` says something it lacked has arrived.
    /// Notes no longer shown are dropped. Nothing else is resolved.
    static func reconcile<Note, Row>(
        notes: [Note],
        id: (Note) -> String,
        cache: [String: Row],
        drafts: [String: Row],
        needsRepair: (Note, Row) -> Bool,
        resolve: (Note) -> Row
    ) -> [String: Row] {
        var out: [String: Row] = [:]
        out.reserveCapacity(min(notes.count, cache.count + drafts.count))
        for note in notes {
            let key = id(note)
            guard let known = cache[key] ?? drafts[key] else { continue }
            out[key] = needsRepair(note, known) ? resolve(note) : known
        }
        return out
    }
}

/// Row data resolved while drawing a row that is not in the cache yet, so it
/// is resolved once rather than on every redraw until the next reconcile.
/// Kept out of the published cache: that must not be written from inside a
/// view update. The next `reconcile` moves these into the cache.
struct FeedRowDrafts<Row> {
    private(set) var rows: [String: Row] = [:]

    /// `cached` when there is one, else this row's draft, resolving it once.
    mutating func row(id: String, cached: Row?, resolve: () -> Row) -> Row {
        if let cached { return cached }
        if let draft = rows[id] { return draft }
        let row = resolve()
        rows[id] = row
        return row
    }

    /// Takes the drafts out, leaving none.
    mutating func take() -> [String: Row] {
        defer { rows = [:] }
        return rows
    }

    mutating func removeAll() { rows = [:] }

    /// Drops the drafts among `ids`, so those rows resolve fresh on their next
    /// draw. True when one was dropped, i.e. the feed must redraw.
    mutating func remove(ids: Set<String>) -> Bool {
        var dropped = false
        for id in ids where rows.removeValue(forKey: id) != nil { dropped = true }
        return dropped
    }
}

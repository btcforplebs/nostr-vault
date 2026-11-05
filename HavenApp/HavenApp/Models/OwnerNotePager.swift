import Foundation

/// Import media's walk through every one of the owner's notes in this
/// device's vault, newest first, page by page back to the oldest. The vault
/// answers a query with at most 250 notes, and Import media used to send one
/// query, so it only ever read the newest 250 (Ted, 2026-11-05). Android twin:
/// `NoteMediaScan.collect`.
enum OwnerNotePager {
    /// Notes asked for per page. The vault may send fewer (it caps at 250),
    /// so a short page is not the end: only a page with nothing new is.
    static let pageLimit = 1_500
    /// Pages at most, so a huge history cannot keep Import media scanning forever.
    static let maxPages = 400

    /// The REQ filter for one page: kind 1 by the owner, at or before `until`.
    static func filter(owner: String, until: Int?) -> [String: Any] {
        var f: [String: Any] = ["kinds": [1], "authors": [owner], "limit": pageLimit]
        if let until { f["until"] = until }
        return f
    }

    /// Every note `fetch` gives for `owner`, newest first. Each next page
    /// starts at the oldest note seen (`until` is inclusive, so that note
    /// comes again and is not new); a page with no new note ends it.
    static func collect<Note>(
        owner: String,
        id: (Note) -> String,
        pubkey: (Note) -> String,
        createdAt: (Note) -> Int,
        fetch: (_ until: Int?) async -> [Note]
    ) async -> [Note] {
        var seen = Set<String>()
        var notes: [Note] = []
        var until: Int?
        for _ in 0..<maxPages {
            let fresh = await fetch(until).filter { pubkey($0) == owner && seen.insert(id($0)).inserted }
            guard let oldest = fresh.map(createdAt).min() else { break }
            notes.append(contentsOf: fresh)
            until = oldest
        }
        return notes
    }
}

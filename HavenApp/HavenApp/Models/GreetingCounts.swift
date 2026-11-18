import Foundation

/// The dashboard's GM tile: how many of your own notes were a "GM", and how
/// many a "Pura Vida", today and all time. Read from your own vault only; no
/// network and nothing published. Twin of Android `GreetingCounts.kt`.
///
/// A note counts only when it is basically just the greeting: the greeting
/// plus at most `maxExtraWords` other words ("gm", "GM!", "Good morning
/// nostr", "gm fam ☕"). Links, nostr: mentions and #tags are ignored, so a
/// "gm" with a photo still counts. A longer note that happens to contain
/// "gm" does not.
enum GreetingCounts {
    struct Counts: Equatable {
        var gmToday = 0, gmAll = 0, pvToday = 0, pvAll = 0
    }

    enum Greeting: Hashable { case gm, puraVida }

    /// The fields of a note the count reads.
    struct Note {
        let id: String
        let pubkey: String
        let kind: Int
        let createdAt: Int64
        let content: String
    }

    /// Words besides the greeting that a note may still have.
    static let maxExtraWords = 2

    private static let link = try! NSRegularExpression(pattern: #"(?i)\b(?:https?://|nostr:|www\.)\S+"#)
    private static let tag = try! NSRegularExpression(pattern: #"(?<!\S)#\S+"#)
    private static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}']+"#)
    private static let gm = try! NSRegularExpression(pattern: #"^(?:gm)+m*$"#)

    /// The greetings `content` is, or empty when it is more than a greeting.
    static func greetings(_ content: String) -> Set<Greeting> {
        let text = replacing(tag, in: replacing(link, in: content)).lowercased()
        let range = NSRange(text.startIndex..., in: text)
        let words = word.matches(in: text, range: range).compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            let w = text[r].trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            return w.isEmpty ? nil : w
        }
        guard !words.isEmpty else { return [] }
        var found = Set<Greeting>()
        var greetingWords = 0
        var i = 0
        while i < words.count {
            let w = words[i]
            let next = i + 1 < words.count ? words[i + 1] : nil
            if gm.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)) != nil {
                found.insert(.gm); greetingWords += 1; i += 1
            } else if w == "good", next == "morning" || next == "mornin" {
                found.insert(.gm); greetingWords += 2; i += 2
            } else if w == "pv" {
                found.insert(.puraVida); greetingWords += 1; i += 1
            } else if w == "pura", next == "vida" {
                found.insert(.puraVida); greetingWords += 2; i += 2
            } else {
                i += 1
            }
        }
        return !found.isEmpty && words.count - greetingWords <= maxExtraWords ? found : []
    }

    /// The counts over `notes` by `author` (kind 1 only), "today" meaning
    /// created at or after `todayStart`. Each id counts once.
    static func count(_ notes: [Note], author: String, todayStart: Int64) -> Counts {
        var counts = Counts()
        var seen = Set<String>()
        let author = author.lowercased()
        for note in notes where note.kind == 1 && note.pubkey.lowercased() == author {
            guard seen.insert(note.id).inserted else { continue }
            let found = greetings(note.content)
            if found.isEmpty { continue }
            let today = note.createdAt >= todayStart
            if found.contains(.gm) { counts.gmAll += 1; if today { counts.gmToday += 1 } }
            if found.contains(.puraVida) { counts.pvAll += 1; if today { counts.pvToday += 1 } }
        }
        return counts
    }

    /// The store read's filter for one page of `author`'s notes, newest
    /// first, at or before `until`.
    static func pageFilter(author: String, until: Int64?, limit: Int) -> [String: Any] {
        var filter: [String: Any] = ["kinds": [1], "authors": [author.lowercased()], "limit": limit]
        if let until { filter["until"] = until }
        return filter
    }

    /// Every note of `author`'s that `read` (one store page per call) gives,
    /// walking back with `until` until a page comes back short. Nil when the
    /// store can't answer. `until` is inclusive, so a second shared at a page
    /// edge is read again and its notes dropped as already seen; a page of
    /// nothing new steps one second past the edge.
    static func readAll(author: String, pageSize: Int, maxPages: Int,
                        read: ([String: Any]) async -> [Note]?) async -> [Note]? {
        var byId: [String: Note] = [:]
        var order: [String] = []
        var until: Int64?
        for _ in 0..<maxPages {
            guard let page = await read(pageFilter(author: author, until: until, limit: pageSize)) else { return nil }
            var added = 0
            var oldest = Int64.max
            for note in page {
                if byId[note.id] == nil { byId[note.id] = note; order.append(note.id); added += 1 }
                oldest = min(oldest, note.createdAt)
            }
            if page.count < pageSize { break }
            until = added == 0 ? oldest - 1 : oldest
        }
        return order.compactMap { byId[$0] }
    }

    /// "GM 12 · PV 3".
    static func label(gm: Int, pv: Int) -> String {
        "GM \(gm.formatted()) · PV \(pv.formatted())"
    }

    private static func replacing(_ regex: NSRegularExpression, in s: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }
}

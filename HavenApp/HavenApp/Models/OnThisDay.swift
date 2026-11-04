import Foundation

/// The rules for Your space's On this day panel, kept free of views so tests
/// can run them. A twin of web-vault's `src/desktop/space/on-this-day.js`:
/// the user's own notes from today's date one and two years ago, read from
/// their own vault (never a relay). Replies stay out: what shows is what the
/// user posted, not their side of someone else's thread.
enum OnThisDay {
    /// How many years back the panel looks.
    static let yearsBack = [1, 2]
    /// Notes drawn per year at most, the oldest of the day first.
    static let perYear = 3

    /// One local day, `years` back from today: `since` its first second,
    /// `until` the first second of the next day (unix seconds).
    struct Window: Equatable {
        let years: Int
        let since: Int64
        let until: Int64
    }

    /// The fields the panel reads from a note.
    struct Note: Equatable, Identifiable {
        let id: String
        let pubkey: String
        let kind: Int
        let createdAt: Int64
        let content: String
        let tags: [[String]]
    }

    /// Today's date `years` back as a local day, or nil when that date did not
    /// exist that year (29 February in a year without one).
    static func window(now: Date, years: Int, calendar: Calendar = .current) -> Window? {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year, let month = today.month, let day = today.day else { return nil }
        var parts = DateComponents(year: year - years, month: month, day: day)
        parts.hour = 0
        guard let start = calendar.date(from: parts),
              calendar.component(.month, from: start) == month,
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return Window(years: years, since: Int64(start.timeIntervalSince1970), until: Int64(end.timeIntervalSince1970))
    }

    /// The windows for every year the panel looks back, skipping dates that did not exist.
    static func windows(now: Date = Date(), years: [Int] = yearsBack, calendar: Calendar = .current) -> [Window] {
        years.compactMap { window(now: now, years: $0, calendar: calendar) }
    }

    /// The vault filter for one window: the user's own kind 1 notes on that day.
    static func filter(owner: String, _ w: Window) -> [String: Any] {
        ["kinds": [1], "authors": [owner], "since": w.since, "until": w.until - 1, "limit": 100]
    }

    /// The user's own top-level kind 1 notes inside the window, oldest first,
    /// at most `max`, each id once.
    static func notes(_ notes: [Note], owner: String, in w: Window, max: Int = perYear) -> [Note] {
        var seen = Set<String>()
        return notes
            .filter {
                $0.kind == 1 && $0.pubkey == owner && $0.createdAt >= w.since && $0.createdAt < w.until
                    && NIP10Thread.parentEventId(kind: $0.kind, tags: $0.tags) == nil
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(max)
            .map { $0 }
    }

    /// "1 year ago", "2 years ago".
    static func yearsText(_ n: Int) -> String { n == 1 ? "1 year ago" : "\(n) years ago" }

    /// One line for a note: its text without picture links, or "Photo" /
    /// "Photos" when that is all it has.
    static func lineText(_ content: String) -> String {
        let words = content.split(whereSeparator: \.isWhitespace).map(String.init)
        let pictures = words.filter(isPicture)
        let text = words.filter { !isPicture($0) }.joined(separator: " ")
        if !text.isEmpty { return text }
        return pictures.count > 1 ? "Photos" : pictures.isEmpty ? "Note" : "Photo"
    }

    private static func isPicture(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        let path = lower.split(separator: "?", maxSplits: 1).first.map(String.init) ?? lower
        return ["png", "jpg", "jpeg", "gif", "webp", "avif"].contains { path.hasSuffix(".\($0)") }
    }
}

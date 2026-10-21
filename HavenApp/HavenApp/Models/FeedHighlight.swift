import Foundation

/// How a NIP-84 highlight (kind 9802) names what it was taken from. Pure, so
/// the feed card and the tests share one copy.
enum FeedHighlight {
    /// The highlighted event: its `a` coordinate (an article) in
    /// `QuoteReference`'s spelling, else its `e` id. Drawn as a quote card
    /// under the passage, so it is fetched and opened like any quote.
    static func sourceReference(tags: [[String]]) -> String? {
        if let coordinate = tags.first(where: { $0.count >= 2 && $0[0] == "a" })?[1] {
            return QuoteReference.coordinatePrefix + coordinate
        }
        return tags.first { $0.count >= 2 && $0[0] == "e" }?[1]
    }

    /// A web page the passage came from, when it came from no event.
    static func sourceURL(tags: [[String]]) -> URL? {
        guard sourceReference(tags: tags) == nil,
              let value = tags.first(where: { $0.count >= 2 && $0[0] == "r" })?[1],
              let url = URL(string: value), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// What the highlighter wrote about the passage (NIP-84 quote highlight).
    static func comment(tags: [[String]]) -> String? {
        let text = tags.first { $0.count >= 2 && $0[0] == "comment" }?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

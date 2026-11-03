import Foundation

/// Messages search: matches a typed query against a conversation's names and
/// its already-decrypted message text. Pure and local by design: it only
/// reads what is on the device, so the query never leaves it (no relay REQ,
/// no NIP-50). Tested in MediaLogicTests.
enum DMSearch {
    /// Case- and accent-blind form used on both sides of a match, so "jose"
    /// finds "José" and "CAFE" finds "café".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The query as searched: trimmed and folded. Empty means "not searching".
    static func normalizedQuery(_ query: String) -> String {
        fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether any of the person's names (display name, name, NIP-05) contains the query.
    static func nameMatches(_ query: String, names: [String?]) -> Bool {
        let q = normalizedQuery(query)
        guard !q.isEmpty else { return false }
        return names.contains { name in
            guard let name, !name.isEmpty else { return false }
            return fold(name).contains(q)
        }
    }

    /// The index of the newest message whose text contains the query.
    /// `texts` are oldest first, as a conversation keeps them.
    static func newestTextMatch(_ query: String, texts: [String]) -> Int? {
        let q = normalizedQuery(query)
        guard !q.isEmpty else { return nil }
        return texts.lastIndex { fold($0).contains(q) }
    }

    /// A one-line excerpt of `text` around the first match, so a hit deep in a
    /// long message still shows the words that matched.
    static func excerpt(_ text: String, query: String, radius: Int = 40) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let q = normalizedQuery(query)
        guard !q.isEmpty, let range = fold(flat).range(of: q) else {
            return String(flat.prefix(radius * 2))
        }
        // Folding keeps character counts for the scripts we fold, but map by
        // offset defensively and clamp to the original string.
        let folded = fold(flat)
        let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let start = max(0, offset - radius)
        let end = min(flat.count, offset + q.count + radius)
        guard start < end else { return String(flat.prefix(radius * 2)) }
        let s = flat.index(flat.startIndex, offsetBy: start)
        let e = flat.index(flat.startIndex, offsetBy: end)
        return (start > 0 ? "…" : "") + flat[s..<e].trimmingCharacters(in: .whitespaces) + (end < flat.count ? "…" : "")
    }
}

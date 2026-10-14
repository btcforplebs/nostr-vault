import Foundation

/// What the Vault's search makes of the notes the local relay matched: which
/// kind of result each one is, and the hashtags and links they carry. Pure, so
/// MediaLogicTests compiles this same file.
enum VaultSearchLogic {

    /// The Vault's result sections, in the order they show.
    enum Section: String, CaseIterable, Equatable {
        case people, notes, articles, media, hashtags, links

        var title: String {
            switch self {
            case .people: return "People"
            case .notes: return "Notes"
            case .articles: return "Articles"
            case .media: return "Media"
            case .hashtags: return "Hashtags"
            case .links: return "Links"
            }
        }

        var symbol: String {
            switch self {
            case .people: return "person.2"
            case .notes: return "doc.text"
            case .articles: return "doc.richtext"
            case .media: return "photo.on.rectangle"
            case .hashtags: return "number"
            case .links: return "link"
            }
        }
    }

    static let articleKind = 30023
    /// NIP-68 pictures, NIP-71 videos (normal and short), and the older
    /// addressable video kinds.
    static let mediaKinds: Set<Int> = [20, 21, 22, 34235, 34236]

    /// Which section a matched note belongs in. Everything that is not an
    /// article or media (kind 1, comments, highlights, polls) is a note.
    static func section(forKind kind: Int) -> Section {
        if kind == articleKind { return .articles }
        if mediaKinds.contains(kind) { return .media }
        return .notes
    }

    /// Hashtags on the matched notes that contain any word of the query,
    /// from the text (`#word`) and from `t` tags, lowercased, deduplicated
    /// and sorted. `#` in the query is ignored, so "#bitcoin" and "bitcoin"
    /// find the same tags.
    static func hashtags(contents: [(content: String, tags: [[String]])], query: String) -> [String] {
        let words = query.lowercased()
            .replacingOccurrences(of: "#", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        var found = Set<String>()
        for item in contents {
            var tags = hashtagsInText(item.content)
            for tag in item.tags where tag.count >= 2 && tag[0] == "t" && !tag[1].isEmpty {
                tags.append(tag[1].lowercased())
            }
            for tag in tags where words.contains(where: { tag.contains($0) }) {
                found.insert(tag)
            }
        }
        return found.sorted()
    }

    /// `#word` hashtags in a note's text, lowercased, without the `#`.
    static func hashtagsInText(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "#(\\w+)") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return text[r].lowercased()
        }
    }

    struct Link: Equatable {
        let url: String
        /// The URL without its scheme, for the row's title.
        let title: String
        let noteId: String
    }

    /// Links in the matched notes, each URL once, in note order. A note that
    /// matched on its text gives its links even when the query is not in the
    /// URL, as the Search tab does. Trailing punctuation that closes a
    /// sentence is not part of the link; a closing bracket the URL itself
    /// opened is (`…/wiki/Foo_(bar)`).
    static func links(notes: [(id: String, content: String)]) -> [Link] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s]+") else { return [] }
        var seen = Set<String>()
        var links: [Link] = []
        for note in notes {
            let range = NSRange(note.content.startIndex..., in: note.content)
            for match in regex.matches(in: note.content, range: range) {
                guard let r = Range(match.range, in: note.content) else { continue }
                let url = trimmingTrailingPunctuation(String(note.content[r]))
                guard seen.insert(url).inserted else { continue }
                let title = url
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                links.append(Link(url: url, title: title, noteId: note.id))
            }
        }
        return links
    }

    private static let openers: [Character: Character] = [")": "(", "]": "["]

    /// Strips what closes the sentence around a URL. `)` and `]` go only
    /// when the URL has more closers than openers, so "(see https://x.y/a)"
    /// loses its paren and "https://en.wikipedia.org/wiki/Foo_(bar)" keeps it.
    static func trimmingTrailingPunctuation(_ raw: String) -> String {
        var url = raw
        while let last = url.last {
            if ".,;:!?\"'".contains(last) {
                url.removeLast()
            } else if let open = Self.openers[last],
                      url.filter({ $0 == last }).count > url.filter({ $0 == open }).count {
                url.removeLast()
            } else {
                break
            }
        }
        return url
    }

    // MARK: - People

    /// The public key a query names: 64 hex characters, or an `npub1…` with a
    /// good checksum, either with or without `nostr:`. Lowercased hex.
    static func pubkey(inQuery query: String) -> String? {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("nostr:") { text = String(text.dropFirst(6)) }
        if text.count == 64, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return text }
        if text.hasPrefix("npub1") { return NpubValidation.hexPubkey(fromNpub: text) }
        return nil
    }

    /// The key to show a bare People row for when the walk found nobody.
    /// An npub is unambiguously a key. Bare hex may be a note id (also 64
    /// hex), so it counts only when a store already holds that profile —
    /// otherwise the row would be a person who does not exist.
    static func keyOnlyPerson(inQuery query: String, hasProfile: (String) -> Bool) -> String? {
        guard let key = pubkey(inQuery: query) else { return nil }
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("nostr:") { text = String(text.dropFirst(6)) }
        return text.hasPrefix("npub1") || hasProfile(key) ? key : nil
    }

    /// Whether a profile the relay walk matched belongs under People. A query
    /// that is a key finds that one person. Any other query has to be in the
    /// names, about or NIP-05: the walk also matches it inside the hex key,
    /// so "ab" or "cafe" would otherwise list nearly everyone.
    static func keepsPerson(pubkey: String, fields: [String?], query: String) -> Bool {
        if let key = self.pubkey(inQuery: query) { return pubkey.lowercased() == key }
        return SearchTermMatcher(query: query)?.matches(fields: fields) ?? false
    }

    // MARK: - Query state

    /// How the Vault's search stands.
    enum Status: Equatable {
        /// Nothing typed, or under two characters.
        case idle
        case searching
        /// The relay walk finished.
        case done
        /// The walk hit its deadline: the results are real, but kinds or
        /// pages it had not reached yet are missing.
        case cutShort
        /// The Vault's relay was not up, so only what the app had already
        /// loaded was searched.
        case inMemory
    }

    /// Which query is on screen and which one the results are for. A search
    /// that lands is kept only if it is for the query in the field now —
    /// the Search tab's rule (it compares the live text too). Comparing with
    /// the last results' query instead left the spinner up for good: type
    /// "ab", then "abc", then back to "ab", and "abc" landed for nothing.
    struct QueryState: Equatable {
        enum Next: Equatable {
            /// Under two characters: drop the results and any search running.
            case clear
            /// The results already on screen are for this query: stop any
            /// search running and show them.
            case keep
            /// Search this query.
            case run(String)
        }

        private(set) var live = ""
        private(set) var resultsQuery = ""
        private(set) var status: Status = .idle
        /// How the search behind the results on screen ended.
        private var resultsStatus: Status = .idle

        /// The field changed.
        mutating func typed(_ query: String) -> Next {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            live = trimmed
            guard trimmed.count >= 2 else {
                resultsQuery = ""
                status = .idle
                resultsStatus = .idle
                return .clear
            }
            // An in-memory or cut-short answer is worth asking again for:
            // the relay may be up now, or answer faster.
            if trimmed == resultsQuery && resultsStatus == .done {
                status = .done
                return .keep
            }
            return .run(trimmed)
        }

        /// A search for `query` starts. False if the field has moved on.
        mutating func started(_ query: String) -> Bool {
            guard query == live else { return false }
            status = .searching
            return true
        }

        /// A search for `query` came back. False, and nothing changes, if
        /// the field no longer holds that query.
        mutating func landed(_ query: String, as result: Status) -> Bool {
            guard query == live else { return false }
            resultsQuery = query
            status = result
            resultsStatus = result
            return true
        }

        mutating func reset() {
            self = QueryState()
        }
    }
}

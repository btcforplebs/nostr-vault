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
    /// sentence is not part of the link.
    static func links(notes: [(id: String, content: String)]) -> [Link] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s]+") else { return [] }
        var seen = Set<String>()
        var links: [Link] = []
        for note in notes {
            let range = NSRange(note.content.startIndex..., in: note.content)
            for match in regex.matches(in: note.content, range: range) {
                guard let r = Range(match.range, in: note.content) else { continue }
                var url = String(note.content[r])
                while let last = url.last, ".,;:!?)]\"'".contains(last) { url.removeLast() }
                guard seen.insert(url).inserted else { continue }
                let title = url
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                links.append(Link(url: url, title: title, noteId: note.id))
            }
        }
        return links
    }
}

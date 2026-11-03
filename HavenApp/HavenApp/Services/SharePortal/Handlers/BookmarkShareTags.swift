import Foundation

/// Save for later: a shared web link as a NIP-51 bookmark (kind 10003, `r`
/// tag), public in the tags or private in the content (a JSON array of tags,
/// NIP-44 encrypted to the account itself). Pure and fixture-tested; Android's
/// BookmarkShareTags.kt does the same. It only edits the list the Bookmarks
/// store fetched (BookmarkShareHandler.save): every other tag, and every
/// other private entry, goes back as it was.
enum BookmarkShareTags {
    static let kind = 10003

    enum Change: Equatable {
        /// Already on the list: nothing to sign.
        case alreadyPublic
        case alreadyPrivate
        /// The new public tags, or the new private tags (to encrypt).
        case publicTags([[String]])
        case privateTags([[String]])
    }

    /// The link a share saves: the page's http(s) address, trimmed; nil when
    /// the share named none.
    static func url(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let lower = s.lowercased()
        guard (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && s.count > 8 else { return nil }
        return s
    }

    static func has(_ tags: [[String]], _ url: String) -> Bool {
        tags.contains { $0.count >= 2 && $0[0] == "r" && $0[1].trimmingCharacters(in: .whitespacesAndNewlines) == url }
    }

    /// Adds `url` publicly or privately. A link already saved either way is
    /// left alone: saving it publicly would show a private bookmark to everyone.
    static func adding(_ url: String, publicTags: [[String]], privateTags: [[String]], privately: Bool) -> Change {
        if has(privateTags, url) { return .alreadyPrivate }
        if has(publicTags, url) { return .alreadyPublic }
        return privately ? .privateTags(privateTags + [["r", url]]) : .publicTags(publicTags + [["r", url]])
    }

    /// The private part's tags: nil when it isn't a JSON array of string
    /// arrays, so a part this device can't read is never written over. An
    /// empty or blank part is no private entries.
    static func privateTags(plaintext: String) -> [[String]]? {
        if plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let data = plaintext.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var out: [[String]] = []
        for entry in array {
            guard let tag = entry as? [Any] else { return nil }
            let strings = tag.compactMap { $0 as? String }
            guard strings.count == tag.count else { return nil }
            out.append(strings)
        }
        return out
    }

    /// Whether a private part is sealed again with NIP-04: when the list's
    /// part already is (an `?iv=` in it), as the mute list path keeps it, so
    /// an app that only reads NIP-04 still sees it. Otherwise NIP-44.
    static func sealsAsNip04(existingContent: String) -> Bool { existingContent.contains("?iv=") }

    static func json(_ tags: [[String]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: tags, options: [.withoutEscapingSlashes]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

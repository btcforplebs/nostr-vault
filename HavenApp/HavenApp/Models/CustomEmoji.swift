import Foundation

/// NIP-30 custom emoji: an event's `["emoji", shortcode, url, setAddress?]`
/// tags name the images its `:shortcode:` text stands for. Kind 7 reactions
/// use the same tag with `:shortcode:` as their whole content.
/// Android: `service/CustomEmoji.kt`.
struct CustomEmoji: Codable, Hashable {
    let shortcode: String
    let url: String
    /// The `30030:<pubkey>:<d>` set it came from, when the tag names one.
    var setAddress: String?

    init(shortcode: String, url: String, setAddress: String? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.setAddress = setAddress
    }

    /// What goes in a note or reaction's content: `:shortcode:`.
    var content: String { ":\(shortcode):" }

    /// The tag that makes `content` an image (NIP-30).
    var tag: [String] {
        if let setAddress { return ["emoji", shortcode, url, setAddress] }
        return ["emoji", shortcode, url]
    }

    /// NIP-30 says `[A-Za-z0-9_]`; other apps also send `-`, so it is accepted too.
    static func isValidShortcode(_ shortcode: String) -> Bool {
        !shortcode.isEmpty && shortcode.unicodeScalars.allSatisfy { s in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s))) || s == "_" || s == "-"
        }
    }

    /// Only http(s) image addresses: no `data:`, `file:` or `javascript:`.
    static func isValidURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return false }
        guard !url.contains(where: { $0.isWhitespace }) else { return false }
        return lower.count > "https://".count
    }

    /// One emoji tag, or nil when it is malformed.
    static func from(tag: [String]) -> CustomEmoji? {
        guard tag.count >= 3, tag[0] == "emoji" else { return nil }
        let shortcode = tag[1]
        let url = tag[2].trimmingCharacters(in: .whitespaces)
        guard isValidShortcode(shortcode), isValidURL(url) else { return nil }
        let set = tag.count > 3 && tag[3].hasPrefix("30030:") ? tag[3] : nil
        return CustomEmoji(shortcode: shortcode, url: url, setAddress: set)
    }

    /// An event's emoji, in tag order. A shortcode tagged twice keeps the
    /// first tag, so the same text always draws the same image.
    static func list(from tags: [[String]]) -> [CustomEmoji] {
        var seen = Set<String>()
        var out: [CustomEmoji] = []
        for tag in tags {
            guard let emoji = from(tag: tag), seen.insert(emoji.shortcode).inserted else { continue }
            out.append(emoji)
        }
        return out
    }

    /// `list(from:)` by shortcode.
    static func byShortcode(_ tags: [[String]]) -> [String: CustomEmoji] {
        Dictionary(list(from: tags).map { ($0.shortcode, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The `shortcode` of a lone `:shortcode:`, or nil.
    static func loneShortcode(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.hasPrefix(":"), trimmed.hasSuffix(":") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        return isValidShortcode(inner) ? inner : nil
    }

    /// A reaction's `:shortcode:` as written when `known` has its image, so a
    /// row can draw it; nil for anything else (the caller's usual display).
    static func shownShortcode(_ raw: String, known: Set<String>) -> String? {
        guard let shortcode = loneShortcode(raw), known.contains(shortcode) else { return nil }
        return ":\(shortcode):"
    }

    /// The custom emoji a kind 7 reaction is: its content is exactly
    /// `:shortcode:` and a tag gives that shortcode's image. Anything else
    /// (Unicode, "+", a shortcode with no tag) is nil.
    static func forReaction(content: String, tags: [[String]]) -> CustomEmoji? {
        guard let shortcode = loneShortcode(content) else { return nil }
        return byShortcode(tags)[shortcode]
    }

    enum Segment: Equatable {
        case text(String)
        case emoji(CustomEmoji)
    }

    /// `text` split into plain runs and the emoji `emojis` has images for.
    static func segments(_ text: String, emojis: [String: CustomEmoji]) -> [Segment] {
        guard !emojis.isEmpty, text.contains(":") else { return [.text(text)] }
        var out: [Segment] = []
        var plain = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: ":") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: ":") else { break }
            let inner = String(rest[afterOpen..<close])
            if isValidShortcode(inner), let emoji = emojis[inner] {
                plain += rest[..<open]
                if !plain.isEmpty { out.append(.text(plain)); plain = "" }
                out.append(.emoji(emoji))
                rest = rest[rest.index(after: close)...]
            } else {
                // Not one of ours: keep the first colon and look again from the second.
                plain += rest[..<close]
                rest = rest[close...]
            }
        }
        plain += rest
        if !plain.isEmpty { out.append(.text(plain)) }
        return out
    }

    /// A kind 7's tags: the note (`e` with a relay hint), its author (`p`),
    /// its kind (`k`), and the NIP-30 tag when the reaction is a custom emoji.
    static func reactionEventTags(noteId: String, relayHint: String, authorPubkey: String, noteKind: Int,
                                  content: String, emojiTag: [String]?) -> [[String]] {
        [["e", noteId, relayHint], ["p", authorPubkey], ["k", String(noteKind)]]
            + reactionTags(content: content, emojiTag: emojiTag)
    }

    /// The NIP-30 tag a reaction carries: `emojiTag` only when `content` is
    /// exactly its `:shortcode:`, so a Unicode reaction never names an image.
    static func reactionTags(content: String, emojiTag: [String]?) -> [[String]] {
        guard let emojiTag, let emoji = from(tag: emojiTag),
              content.trimmingCharacters(in: .whitespacesAndNewlines) == emoji.content else { return [] }
        return [emoji.tag]
    }
}

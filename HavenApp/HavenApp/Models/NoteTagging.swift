import Foundation

/// The tags a composed kind-1 note carries *about its own content*: the
/// hashtags the author typed (NIP-24 `t`) and a description of each piece of
/// media it publishes (NIP-92 `imeta`).
///
/// Both are pure string work, kept out of `ComposeView`/`ComposeNoteScreen` so
/// the macOS, iOS and Android editors agree about what a note advertises, and
/// so the rules are testable without a view. The Kotlin twin lives at
/// `NostrVault/app/src/main/java/com/nostrvault/data/model/NoteTagging.kt`.
enum NoteTagging {

    // MARK: - Hashtags

    /// `#tag` runs that are not part of a URL or a `nostr:` reference.
    ///
    /// A `t` tag is what makes a note findable by hashtag — our own Search tab
    /// builds its trending list from `t` tags (`Views/Search/SearchView.swift`),
    /// as does every other client's tag feed. NIP-24 stores the value without
    /// the `#` and lower-cased, so `#Bitcoin` and `#bitcoin` are one tag.
    ///
    /// Rules, in the order they bite:
    /// - a token that is a URL or a `nostr:`/`wss:` reference contributes
    ///   nothing, so `https://host/page#section` is a fragment, not a tag;
    /// - `#` must not follow a letter, digit or `_`, so `C#` inside a word and
    ///   `a#b` are left alone;
    /// - the run must contain at least one letter, so `#1` reads as "number 1"
    ///   rather than a tag;
    /// - duplicates collapse case-insensitively, first spelling wins the order.
    static func hashtags(in text: String) -> [String] {
        guard let regex = hashtagRegex else { return [] }

        var found: [String] = []
        var seen = Set<String>()

        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if isReference(token) { continue }

            let candidate = String(token)
            let ns = candidate as NSString
            let matches = regex.matches(in: candidate, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                let tag = ns.substring(with: match.range(at: 1)).lowercased()
                guard tag.contains(where: { $0.isLetter }) else { continue }
                guard tag.count <= maxHashtagLength else { continue }
                if seen.insert(tag).inserted {
                    found.append(tag)
                }
            }
        }

        return found
    }

    /// `t` tags, ready to append to an event's tag list.
    static func hashtagTags(in text: String) -> [[String]] {
        hashtags(in: text).map { ["t", $0] }
    }

    /// A tag longer than this is almost certainly a run-together sentence or a
    /// hex blob, not something anyone browses by.
    private static let maxHashtagLength = 64

    private static let hashtagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+)"#)
    }()

    private static func isReference<S: StringProtocol>(_ token: S) -> Bool {
        let lowered = token.lowercased()
        return lowered.hasPrefix("http://")
            || lowered.hasPrefix("https://")
            || lowered.hasPrefix("ws://")
            || lowered.hasPrefix("wss://")
            || lowered.hasPrefix("nostr:")
    }

    // MARK: - NIP-92 imeta

    /// Everything we know about one uploaded attachment at publish time.
    struct MediaDescriptor {
        let url: String
        /// MIME type, e.g. `image/jpeg`. Omitted from the tag when unknown.
        var mimeType: String?
        /// SHA-256 of the *original* file, hex. Blossom keys blobs by this, so
        /// it is already computed before the upload starts.
        var sha256: String?
        /// Pixel dimensions. Lets a reader reserve the right box before the
        /// bytes arrive — `MediaAspect.kt` and the feed's image views read it,
        /// which is why our own media used to shift our own layout.
        var pixelWidth: Int?
        var pixelHeight: Int?
        /// Author-supplied description. The only thing that makes the image
        /// mean anything to a screen-reader user.
        var alt: String?
        var byteCount: Int?
    }

    /// One flat `imeta` tag per NIP-92: `["imeta", "url …", "m …", "x …", …]`.
    ///
    /// Fields whose value we don't have are left out entirely rather than
    /// emitted empty — a reader that sees `dim ` has to guess, one that sees no
    /// `dim` knows to measure. A descriptor with no URL produces no tag.
    static func imetaTag(for media: MediaDescriptor) -> [String]? {
        let url = media.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        var fields = ["url \(url)"]
        if let mime = media.mimeType, !mime.isEmpty { fields.append("m \(mime)") }
        if let sha = media.sha256, !sha.isEmpty { fields.append("x \(sha)") }
        if let w = media.pixelWidth, let h = media.pixelHeight, w > 0, h > 0 {
            fields.append("dim \(w)x\(h)")
        }
        if let size = media.byteCount, size > 0 { fields.append("size \(size)") }
        if let alt = media.alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
            // A newline inside a field would split the tag's meaning for a
            // reader that parses by prefix; collapse to spaces.
            let flattened = alt.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            fields.append("alt \(flattened)")
        }

        return ["imeta"] + fields
    }

    static func imetaTags(for media: [MediaDescriptor]) -> [[String]] {
        media.compactMap { imetaTag(for: $0) }
    }
}

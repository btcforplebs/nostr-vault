import Foundation

/// Decodes the HTML character references that appear in OpenGraph metadata.
///
/// `og:title` and `og:description` are attribute values in a real HTML page, so
/// they arrive encoded: an apostrophe is `&#39;`, an ampersand `&amp;`. Rendered
/// as-is, a link preview reads "Bob&#39;s blog". Only the entities that actually
/// turn up in page titles are named here; anything else numeric is decoded by
/// code point, and anything unrecognised is left exactly as it came so no text
/// is lost.
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
        "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼",
    ]

    /// Longest entity name plus the `&`, `#`, `x` and `;` around a numeric form.
    private static let maxReferenceLength = 12

    static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }

        var result = ""
        result.reserveCapacity(string.count)
        var rest = Substring(string)

        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<ampersand]
            let after = rest.index(after: ampersand)
            // A reference ends at the first ";" — but an unescaped "&" in prose
            // has no ";" near it, so only look a short way ahead.
            let window = rest.index(after, offsetBy: maxReferenceLength, limitedBy: rest.endIndex) ?? rest.endIndex
            guard let semicolon = rest[after..<window].firstIndex(of: ";") else {
                result.append("&")
                rest = rest[after...]
                continue
            }

            let body = rest[after..<semicolon]
            guard let decoded = decodeReference(body) else {
                // Not a reference. Emit the "&" alone and carry on from the very
                // next character — the ";" we found may belong to a real entity
                // further along ("A & B &amp; C"), and skipping to it would eat one.
                result.append("&")
                rest = rest[after...]
                continue
            }
            result += decoded
            rest = rest[rest.index(after: semicolon)...]
        }

        result += rest
        return result
    }

    private static func decodeReference(_ body: Substring) -> String? {
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let code = value, let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }

        return named[body.lowercased()]
    }
}

/// Escaping for text that is fed to `AttributedString(markdown:)`.
///
/// Note text is rendered as markdown, so anything that looks like a link
/// becomes one. Without this a post could carry `[@jack](nostr:npub1<mallory>)`
/// — reading "@jack", opening Mallory — and a kind-0 name like
/// `Alice](https://evil.example) [x` could break out of the mention link the
/// app builds around it (Tron, mention-tap review).
enum MarkdownEscape {
    /// For a string the app places inside a link label it builds.
    static func label(_ text: String) -> String {
        escape(text, characters: #"\[]()*_`~"#)
    }

    /// For note content before the app adds its own links: hand-written link
    /// syntax is shown as typed, so the only links are the ones the app made.
    /// Bold and italics still work.
    static func linkSyntax(in text: String) -> String {
        escape(text, characters: #"\[]"#)
    }

    private static func escape(_ text: String, characters: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if characters.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

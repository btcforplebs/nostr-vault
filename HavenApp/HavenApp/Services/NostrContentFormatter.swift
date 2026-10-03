import SwiftUI
import Foundation

public struct NostrContentFormatter {
    // Pre-compiled regex patterns — avoids re-creating on every format() call
    private static let npubRegex = try! NSRegularExpression(pattern: "nostr:(npub1[a-z0-9]+)")
    private static let nprofileRegex = try! NSRegularExpression(pattern: "nostr:(nprofile1[a-z0-9]+)")
    private static let noteRegex = try! NSRegularExpression(pattern: "nostr:(note1[a-z0-9]+)")
    private static let neventRegex = try! NSRegularExpression(pattern: "nostr:(nevent1[a-z0-9]+)")
    private static let naddrRegex = try! NSRegularExpression(pattern: "nostr:(naddr1[a-z0-9]+)")
    /// Matches bare HTTP(S) URLs that are NOT already inside markdown link syntax.
    /// A #hashtag: letters/digits/underscore after a # that starts a word, so
    /// URL fragments (`page#top`) and markdown labels are left alone.
    private static let hashtagRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/#&\]\[])#([\p{L}\p{N}_]*\p{L}[\p{L}\p{N}_]*)"#)
    private static var httpURLRegex: NSRegularExpression { NoteURLs.httpRegex }

    // Result cache — keyed on content + mediaURLs count. Note content is immutable
    // so the formatted result can be safely reused.
    private static let cache = NSCache<NSString, Box<AttributedString>>()

    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Formats note content for display.
    ///
    /// Quote references (`nostr:note1…`, `nevent1…`, `naddr1…`) are removed from
    /// the text: every view that shows note content either renders the quoted
    /// event as its own card underneath, or is a two-line preview with no room
    /// for one. Leaving the reference in the text produced a bare blue "Quote"
    /// word beside — or instead of — the card.
    @MainActor
    public static func format(_ content: String, mediaURLs: [URL] = []) -> AttributedString {
        let key = "\(content.hashValue)_\(mediaURLs.count)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let result = formatUncached(content, mediaURLs: mediaURLs)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    @MainActor
    private static func formatUncached(_ content: String, mediaURLs: [URL]) -> AttributedString {
        var text = content

        // Strip URLs the view renders on its own — media as thumbnails,
        // links as preview cards.
        text = stripURLs(mediaURLs, from: text)

        // Resolve nostr:npub and nostr:nprofile
        text = replaceWithLinks(in: text, regex: npubRegex, template: "nostr:$1")
        text = replaceWithLinks(in: text, regex: nprofileRegex, template: "nostr:$1")

        // Quote references are rendered as cards by the view, not as text.
        text = stripQuoteReferences(from: text)

        // Convert bare HTTP(S) URLs to clickable markdown links
        text = linkifyURLs(in: text)

        // #hashtags open that hashtag's feed (see HashtagLink).
        text = linkifyHashtags(in: text)

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var attrString = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))

            // Clear any embedded foreground colors so SwiftUI's .foregroundColor() takes effect
            for run in attrString.runs {
                if run.foregroundColor != nil {
                    let range = run.range
                    attrString[range].foregroundColor = nil
                }
            }

            return attrString
        } catch {
            return AttributedString(text)
        }
    }

    /// Turns #hashtags into markdown links to `nostrvault://hashtag/<tag>`.
    /// Runs after URL linkification and skips anything inside a markdown
    /// link's target, so a URL's own `#fragment` stays part of the URL.
    private static func linkifyHashtags(in text: String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        // Ranges of "(...)" link targets produced by linkifyURLs/mentions.
        let targets = (try? NSRegularExpression(pattern: #"\]\([^)]*\)"#))?
            .matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range) ?? []
        for match in hashtagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if targets.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            let tag = ns.substring(with: match.range(at: 1))
            guard let url = HashtagLink.url(for: tag) else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "[#\(tag)](\(url.absoluteString))"
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Converts bare HTTP(S) URLs to markdown links so they become tappable in the attributed string.
    /// Skips URLs already wrapped in markdown link syntax (e.g. `[label](url)`).
    private static func linkifyURLs(in text: String) -> String {
        let nsString = text as NSString
        let matches = httpURLRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var result = text
        var offset = 0

        for match in matches {
            let range = match.range
            let urlString = nsString.substring(with: range)

            // Skip if this URL is already inside a markdown link: [text](URL)
            let adjustedStart = range.location + offset
            if adjustedStart > 1 {
                let before = (result as NSString).substring(with: NSRange(location: adjustedStart - 1, length: 1))
                if before == "(" { continue }
            }

            // Show a short display label: domain + truncated path
            let displayLabel: String
            if let url = URL(string: urlString), let host = url.host {
                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let path = url.path
                if path.count > 1 && path != "/" {
                    let truncatedPath = path.count > 20 ? String(path.prefix(20)) + "..." : path
                    displayLabel = domain + truncatedPath
                } else {
                    displayLabel = domain
                }
            } else {
                displayLabel = urlString
            }

            let markdownLink = "[\(displayLabel)](\(urlString))"
            let fullRange = NSRange(location: adjustedStart, length: range.length)
            result = (result as NSString).replacingCharacters(in: fullRange, with: markdownLink)
            offset += markdownLink.count - range.length
        }

        return result
    }


    // MARK: - Plain-text mention resolution (for compact views)

    /// Removes each URL from `text` where it stands whole; see `NoteURLs.strip`.
    static func stripURLs(_ urls: [URL], from text: String) -> String {
        NoteURLs.strip(urls, from: text)
    }

    /// Every HTTP(S) URL in `text`, in order, without duplicates.
    static func httpURLs(in text: String) -> [URL] {
        let ns = text as NSString
        var seen = Set<String>()
        return NoteURLs.cardRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range)) }
            .filter { seen.insert($0.absoluteString).inserted }
    }

    /// Replaces nostr:npub and nostr:nprofile with @ProfileName as plain text,
    /// without generating markdown links or AttributedStrings.
    ///
    /// Quote references are dropped rather than shown: this feeds two-line
    /// compact previews, which have no room for a quoted card, and the raw
    /// `nostr:nevent1…` bech32 is unreadable in a preview.
    @MainActor
    public static func resolveMentionsPlainText(_ content: String) -> String {
        var text = content
        text = resolveMentionNames(in: text, regex: npubRegex)
        text = resolveMentionNames(in: text, regex: nprofileRegex)
        text = stripQuoteReferences(from: text)
        return text
    }

    private static func stripQuoteReferences(from text: String) -> String {
        var result = text
        for regex in [noteRegex, neventRegex, naddrRegex] {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private static func resolveMentionNames(in text: String, regex: NSRegularExpression) -> String {
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        var result = text
        var offset = 0
        for match in matches {
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            let matchedValue = nsString.substring(with: match.range(at: 1))
            var hexPubkey: String?
            if matchedValue.hasPrefix("npub1") {
                if let decoded = Bech32.decode(matchedValue) {
                    hexPubkey = decoded.hexString
                }
            } else if matchedValue.hasPrefix("nprofile1") {
                if let decoded = Bech32.decode(matchedValue) {
                    var data = decoded.data
                    while data.count >= 2 {
                        let type = data.removeFirst()
                        let length = Int(data.removeFirst())
                        if data.count >= length {
                            let value = data.prefix(length)
                            if type == 0 && length == 32 {
                                hexPubkey = value.map { String(format: "%02x", $0) }.joined()
                                break
                            }
                            data.removeFirst(length)
                        } else {
                            break
                        }
                    }
                }
            }
            let displayLabel: String
            if let hex = hexPubkey, let name = NostrService.shared.profiles[hex]?.bestName {
                displayLabel = "@\(name)"
            } else {
                let preview = matchedValue.prefix(12)
                displayLabel = "@\(preview)..."
                if let hex = hexPubkey {
                    NostrService.shared.fetchMissingProfiles(for: [hex])
                }
            }
            let prevLength = fullRange.length
            result = (result as NSString).replacingCharacters(in: fullRange, with: displayLabel)
            offset += displayLabel.count - prevLength
        }
        return result
    }

    @MainActor
    private static func replaceWithLinks(in text: String, regex: NSRegularExpression, template: String) -> String {
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var result = text
        var offset = 0

        for match in matches {
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            let matchedValue = nsString.substring(with: match.range(at: 1))

            var hexPubkey: String?

            if matchedValue.hasPrefix("npub1") {
                if let decoded = Bech32.decode(matchedValue) {
                    hexPubkey = decoded.hexString
                }
            } else if matchedValue.hasPrefix("nprofile1") {
                if let decoded = Bech32.decode(matchedValue) {
                    // TLV parsing for nprofile: Type 0 is the pubkey (32 bytes)
                    var data = decoded.data
                    while data.count >= 2 {
                        let type = data.removeFirst()
                        let length = Int(data.removeFirst())
                        if data.count >= length {
                            let value = data.prefix(length)
                            if type == 0 && length == 32 {
                                hexPubkey = value.map { String(format: "%02x", $0) }.joined()
                                break
                            }
                            data.removeFirst(length)
                        } else {
                            break
                        }
                    }
                }
            }

            var displayLabel: String
            if let hex = hexPubkey {
                if let name = NostrService.shared.profiles[hex]?.bestName {
                    displayLabel = "@\(name)"
                } else {
                    // Use truncated npub as placeholder and trigger fetch
                    let preview = matchedValue.prefix(12)
                    displayLabel = "@\(preview)..."
                    NostrService.shared.fetchMissingProfiles(for: [hex])
                }
            } else {
                // Fallback for a mention whose bech32 will not decode.
                let preview = matchedValue.prefix(12)
                displayLabel = "@\(preview)..."
            }

            // Add markdown bolding so it's even more noticeable
            let markdownLink = "**[\(displayLabel)](nostr:\(matchedValue))**"
            let prevLength = fullRange.length
            result = (result as NSString).replacingCharacters(in: fullRange, with: markdownLink)
            offset += markdownLink.count - prevLength
        }

        return result
    }
}

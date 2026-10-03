import Foundation

/// Metadata carried by a NIP-23 long-form event (kind 30023) in its tags.
///
/// Both the Articles feed and the Recipes feed read the same kind; recipes are
/// simply long-form events tagged `zapcooking` / `nostrcooking`. Everything the
/// card needs — title, hero image, summary, publication date — lives in tags,
/// so a card can render without touching the (potentially large) body.
struct LongFormMetadata: Equatable {
    let title: String?
    let summary: String?
    let imageURL: URL?
    let publishedAt: Date?
    /// The `d` tag: the stable identifier half of the event's address.
    let identifier: String?
    /// Lowercased `t` tags, in event order.
    let topics: [String]

    /// Reading time in minutes, rounded up, at 200 words per minute.
    /// `nil` when the body is empty.
    static func readingTimeMinutes(for body: String) -> Int? {
        let words = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard words > 0 else { return nil }
        return max(1, Int((Double(words) / 200.0).rounded(.up)))
    }

    init(tags: [[String]]) {
        func firstValue(_ name: String) -> String? {
            guard let raw = tags.first(where: { $0.count >= 2 && $0[0] == name })?[1] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        self.title = firstValue("title")
        self.summary = firstValue("summary")
        self.identifier = firstValue("d")
        self.imageURL = firstValue("image").flatMap { URL(string: $0) }
        // `published_at` is a unix timestamp as a string (NIP-23). Some clients
        // write it with a fractional part, so parse as Double rather than Int.
        self.publishedAt = firstValue("published_at")
            .flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0) }
        self.topics = tags
            .filter { $0.count >= 2 && $0[0] == "t" }
            .map { $0[1].lowercased() }
    }
}

extension FeedNote {
    /// Tag-derived metadata for a long-form event. Meaningless for kind 1.
    var longFormMetadata: LongFormMetadata { LongFormMetadata(tags: tags) }

    /// Title for display, falling back to the first non-empty line of the body
    /// so an article with no `title` tag still reads as an article rather than
    /// as an untitled card.
    var longFormDisplayTitle: String {
        if let title = longFormMetadata.title { return title }
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
        if let firstLine, !firstLine.isEmpty { return String(firstLine.prefix(120)) }
        return "Untitled"
    }

    /// The date to show on a long-form card: the author's stated publication
    /// date when present, otherwise the event's own timestamp. An edited
    /// article gets a fresh `created_at`, so `published_at` is the honest one.
    var longFormDisplayDate: Date { longFormMetadata.publishedAt ?? createdAt }
}

/// One renderable block of a markdown body.
///
/// Long-form Nostr content is markdown, and real recipes carry their
/// ingredients and directions as markdown headings and bullet lists inside
/// `content` rather than as tags. This is a deliberately small subset —
/// headings, bullets, quotes, code, images and paragraphs — chosen to cover
/// what long-form authors actually write, not to be a complete parser.
enum MarkdownBlock: Identifiable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case ordered(index: Int, text: String)
    case quote(String)
    case code(String)
    case image(URL)
    case rule

    /// The markdown of a block a reader can highlight; nil for code, images
    /// and rules.
    var highlightableText: String? {
        switch self {
        case .heading(_, let text), .paragraph(let text), .bullet(let text),
             .ordered(_, let text), .quote(let text):
            return text
        case .code, .image, .rule:
            return nil
        }
    }

    var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level):\(text)"
        case .paragraph(let text): return "p:\(text)"
        case .bullet(let text): return "b:\(text)"
        case .ordered(let index, let text): return "o\(index):\(text)"
        case .quote(let text): return "q:\(text)"
        case .code(let text): return "c:\(text)"
        case .image(let url): return "i:\(url.absoluteString)"
        case .rule: return "rule"
        }
    }
}

enum MarkdownParser {
    /// Splits a markdown body into renderable blocks.
    ///
    /// Consecutive non-blank lines are joined into one paragraph so that
    /// hard-wrapped source text does not render as a stack of one-line
    /// paragraphs.
    static func parse(_ body: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            // A paragraph that is nothing but an image link becomes an image block.
            if let url = standaloneImageURL(in: text) {
                blocks.append(.image(url))
            } else {
                blocks.append(.paragraph(text))
            }
        }

        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCodeFence = false
                } else {
                    flushParagraph()
                    inCodeFence = true
                }
                continue
            }
            if inCodeFence {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                // CommonMark requires whitespace after the hashes. Without this
                // check a line starting with a hashtag — common in Nostr
                // long-form bodies — renders as a giant H1.
                let afterHashes = line.dropFirst(hashes)
                if hashes <= 6, afterHashes.first == " " || afterHashes.first == "\t" {
                    let text = afterHashes.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        flushParagraph()
                        blocks.append(.heading(level: hashes, text: text))
                        continue
                    }
                }
            }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let url = standaloneImageURL(in: text) {
                    blocks.append(.image(url))
                } else {
                    blocks.append(.bullet(text))
                }
                continue
            }

            if let match = orderedListItem(line) {
                flushParagraph()
                blocks.append(.ordered(index: match.0, text: match.1))
                continue
            }

            paragraph.append(line)
        }

        if inCodeFence && !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// `1. text` / `12) text` -> (1, "text"). Returns nil for anything else.
    private static func orderedListItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3, let index = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (index, text)
    }

    /// Returns the URL when `text` is only an image — either `![alt](url)` or a
    /// bare URL with an image extension.
    private static func standaloneImageURL(in text: String) -> URL? {
        if text.hasPrefix("!["), let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            let urlPart = inner.split(separator: " ").first.map(String.init) ?? String(inner)
            return URL(string: urlPart)
        }
        guard !text.contains(" "), let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased()) ? url : nil
    }

    /// Strips markdown syntax down to plain text, for summaries and previews.
    static func plainText(_ body: String, limit: Int = 300) -> String {
        var out: [String] = []
        for block in parse(body) {
            switch block {
            case .heading(_, let text), .paragraph(let text), .bullet(let text), .quote(let text):
                out.append(text)
            case .ordered(_, let text):
                out.append(text)
            case .code, .image, .rule:
                continue
            }
            if out.joined(separator: " ").count >= limit { break }
        }
        let joined = out.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }
}

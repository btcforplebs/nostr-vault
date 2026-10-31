import Foundation

/// A note that embeds a live stream (`nostr:naddr1…` of kind 30311) draws
/// the stream as its card. The links written next to that reference — the
/// stream's `.m3u8` playlist, its cover picture — are the same stream again:
/// they drew a bare stream-link card and the picture a second time, with a
/// blank gap where the reference was (Logen's "Live now" note, 2026-10-31).
/// This takes them out so the text and the card are the only blocks.
///
/// Kept free of SwiftUI so `MediaLogicTests` can compile it.
enum LiveNoteCleanup {
    /// What the note body draws: text, media and link cards.
    struct Body: Equatable {
        var content: String
        var mediaURLs: [URL]
        var linkURLs: [URL]
    }

    /// The live streams a note's text embeds, in order, repeats dropped.
    /// Only `nostr:`-prefixed references, after `QuoteReference.prefixBare`.
    static func liveCoordinates(in content: String) -> [(pubkey: String, dTag: String)] {
        var seen = Set<String>()
        return QuoteReference.identifiers(in: content).compactMap { id in
            guard case .address(let coordinate)? = QuoteReference.target(ofBech32: id),
                  let parts = QuoteReference.parseCoordinate(coordinate),
                  parts.kind == NostrWebLink.liveStreamKind,
                  seen.insert(coordinate).inserted else { return nil }
            return (parts.pubkey, parts.dTag)
        }
    }

    /// The `QuoteReference` coordinate (`naddr:30311:<pk>:<d>`) for each live stream embedded.
    static func liveQuoteIds(in content: String) -> [String] {
        liveCoordinates(in: content).map {
            QuoteReference.coordinate(kind: NostrWebLink.liveStreamKind, pubkey: $0.pubkey, dTag: $0.dTag)
        }
    }

    /// The links a stream event names for itself: what it plays and what it shows.
    static func streamURLs(tags: [[String]]) -> Set<String> {
        let names: Set<String> = ["streaming", "recording", "image", "thumb"]
        return Set(tags.compactMap { tag in
            guard tag.count >= 2, names.contains(tag[0]), let url = URL(string: tag[1]) else { return nil }
            return url.absoluteString
        })
    }

    /// `body` with the embedded streams' own links taken out. With no live
    /// reference in the text it is returned unchanged.
    ///
    /// Dropped: any http(s) link whose path ends `.m3u8` (a playlist beside a
    /// live card is that stream), and any link equal to a URL in
    /// `streamURLs` (the resolved stream events' `streaming` / `recording` /
    /// `image` / `thumb`). The live `nostr:naddr1…` text goes too, as the
    /// formatter strips it anyway. A line left empty by a removal is
    /// removed, and the ends are trimmed, so no blank gap stays behind.
    static func clean(_ body: Body, streamURLs: Set<String> = []) -> Body {
        guard !liveCoordinates(in: body.content).isEmpty else { return body }
        let drop: (String) -> Bool = { link in
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return false }
            return url.path.lowercased().hasSuffix(".m3u8") || streamURLs.contains(url.absoluteString)
        }
        let content = QuoteReference.prefixBare(body.content)
        var lines: [String] = []
        for line in content.components(separatedBy: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let kept = words.filter { word in
                let token = trimPunctuation(word.trimmingCharacters(in: .whitespaces))
                if token.isEmpty { return true }
                if drop(token) { return false }
                if token.lowercased().hasPrefix("nostr:"), isLiveReference(String(token.dropFirst(6))) { return false }
                return true
            }
            let rebuilt = kept.joined(separator: " ")
            let emptied = rebuilt.trimmingCharacters(in: .whitespaces).isEmpty
                && !line.trimmingCharacters(in: .whitespaces).isEmpty
            if emptied { continue }
            lines.append(kept.count == words.count ? line : rebuilt.trimmingCharacters(in: .whitespaces))
        }
        // Blank lines that only separated a removed block from the rest.
        let text = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Body(content: text,
                    mediaURLs: body.mediaURLs.filter { !drop($0.absoluteString) },
                    linkURLs: body.linkURLs.filter { !drop($0.absoluteString) })
    }

    private static func isLiveReference(_ bech: String) -> Bool {
        guard case .address(let coordinate)? = QuoteReference.target(ofBech32: bech),
              let parts = QuoteReference.parseCoordinate(coordinate) else { return false }
        return parts.kind == NostrWebLink.liveStreamKind
    }

    /// Sentence punctuation after a link is not part of it ("see https://x/a.m3u8.").
    private static func trimPunctuation(_ s: String) -> String {
        var s = s
        while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
        return s
    }
}

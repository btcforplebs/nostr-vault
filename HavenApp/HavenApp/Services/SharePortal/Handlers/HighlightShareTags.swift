import Foundation

/// NIP-84 tags for a highlight shared from a web page or another app (kind
/// 9802). Pure, so it is unit tested; Android's HighlightShareTags.kt builds
/// the same list.
///
/// - `r` names the page, marked `source` (NIP-84: the thing highlighted).
/// - No `context` tag: the review card says "Delete what you don't want to
///   keep", so text the person deleted must not go out behind their back.
///   Phase 2 may add it only if the card shows it with a way to turn it off.
/// - `comment` makes it a quote highlight.
enum HighlightShareTags {
    static let kind = 9802

    static func tags(url: String?, passage: String, comment: String) -> [[String]] {
        var out: [[String]] = []
        let p = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), isWeb(url) {
            out.append(["r", url, "source"])
        }
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { out.append(["comment", c]) }
        out.append(["alt", "Highlight: \"\(p)\""])
        return out
    }

    private static func isWeb(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }
}

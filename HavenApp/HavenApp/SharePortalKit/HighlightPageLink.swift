import Foundation

/// The optional "Page link" on a highlight that arrived without one. Safari's
/// text-menu Share… sends only the selected words, so the person can paste the
/// page's address; it goes out as the highlight's `r` tag. Pure, so it is unit
/// tested; Android's HighlightPageLink.kt reads a typed link the same way.
enum HighlightPageLink {
    enum Check: Equatable {
        /// Nothing typed: the highlight goes out without a link.
        case empty
        /// A web address, with https:// added when it was left off.
        case link(String)
        /// Typed but not a web address: Send/Publish wait until it is fixed or cleared.
        case notALink
    }

    static let label = "Page link (optional)"
    static let placeholder = "https://…"
    static let hint = "Safari's text menu shares only the words. Paste the page's address to link the highlight to it."
    static let problem = "That doesn't look like a web address."

    static func check(_ typed: String) -> Check {
        let s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .empty }
        if s.contains(where: { $0.isWhitespace }) { return .notALink }
        let lower = s.lowercased()
        let full: String
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") { full = s }
        else if lower.contains("://") || lower.hasPrefix("//") { return .notALink }
        else { full = "https://" + s }
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return .notALink }
        return .link(full)
    }

    /// The link to publish, or nil (empty or not a link).
    static func link(_ typed: String) -> String? {
        if case .link(let url) = check(typed) { return url }
        return nil
    }
}

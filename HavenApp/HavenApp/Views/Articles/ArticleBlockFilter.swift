import Foundation

/// An article's highlights, likes and comments with blocked people's taken
/// out, before they are counted or drawn, so a blocked person's words and
/// picture never show under an article and their comments are not counted.
///
/// Zap receipts stay: they are signed by the recipient's Lightning provider,
/// not by whoever sent the zap.
enum ArticleBlockFilter {
    static func visibleEvents(_ events: [[String: Any]], blocked: Set<String>) -> [[String: Any]] {
        guard !blocked.isEmpty else { return events }
        return events.filter { event in
            if (event["kind"] as? Int) == ArticleEngagement.zapReceiptKind { return true }
            return !BlockedPeople.isBlocked(event["pubkey"] as? String ?? "", in: blocked)
        }
    }

    /// Comments, replies and highlights from outside your Web of Trust
    /// (`TrustGate`, the Global rule) taken out too. Likes and zaps stay:
    /// they only add to counts. The article's author and you always show.
    static func trustedEvents(_ events: [[String: Any]], trusted: Set<String>?,
                              always: Set<String>) -> [[String: Any]] {
        guard trusted != nil else { return events }
        let words: Set<Int> = [ArticleEngagement.commentKind, ArticleEngagement.noteKind, ArticleEngagement.highlightKind]
        return events.filter { event in
            guard let kind = event["kind"] as? Int, words.contains(kind) else { return true }
            return TrustGate.allows(event["pubkey"] as? String ?? "", trusted: trusted, always: always)
        }
    }
}

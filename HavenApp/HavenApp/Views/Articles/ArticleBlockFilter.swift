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
}

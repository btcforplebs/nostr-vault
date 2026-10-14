import Foundation

/// What a block means for direct messages and quoted notes. A gift-wrapped DM is signed by a
/// throwaway key, so neither the relay nor the notification marker can tell
/// who sent it; only the opened message names the person. These checks run on
/// that real sender.
///
/// A block hides, it never deletes: a blocked person's messages stay stored,
/// so unblocking brings the conversation back.
enum BlockedPeople {
    static func isBlocked(_ hexPubkey: String, in blocked: Set<String>) -> Bool {
        !hexPubkey.isEmpty && blocked.contains(hexPubkey.lowercased())
    }

    /// Conversations are keyed by the other person's hex pubkey. One with a
    /// blocked person is left out, including what you sent them.
    static func visibleConversations<C>(_ conversations: [C], blocked: Set<String>,
                                        counterparty: (C) -> String) -> [C] {
        guard !blocked.isEmpty else { return conversations }
        return conversations.filter { !isBlocked(counterparty($0), in: blocked) }
    }

    /// Whether an incoming message counts as unread and may notify. Your own
    /// copies never do; a blocked sender never does, so unblocking does not
    /// surface a backlog of unread messages from while they were blocked.
    static func mayAlert(sender: String, isFromMe: Bool, blocked: Set<String>) -> Bool {
        !isFromMe && !isBlocked(sender, in: blocked)
    }

    /// Whether a quoted note may be drawn. Someone you follow can quote a
    /// blocked person, and the feed filter only looks at the quoting note, so
    /// the quote card itself checks. A hidden quote shows neither the blocked
    /// person's words nor their picture.
    ///
    /// A live stream (kind 30311) is the streamer's, not its signer's:
    /// zap.stream and shosho.live sign with their own service key and name the
    /// streamer in the `Host` p tag, so both are checked, as the Live tab does.
    static func showsQuote(author: String, kind: Int, tags: [[String]], blocked: Set<String>) -> Bool {
        guard !blocked.isEmpty else { return true }
        if isBlocked(author, in: blocked) { return false }
        if kind == 30311, isBlocked(LiveChat.hostPubkey(authorPubkey: author, tags: tags), in: blocked) {
            return false
        }
        return true
    }
}

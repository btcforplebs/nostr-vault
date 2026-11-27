import Foundation

extension MuteList {
    /// Whether a muted word hides a whole DM conversation: any message the
    /// other person sent has one as a whole word. What you sent never hides
    /// it (Logen 2026-11-27: the conversation row goes, not just the message).
    func hidesConversation(_ messages: [DMMessage]) -> Bool {
        guard !words.isEmpty else { return false }
        return messages.contains { !$0.isFromMe && MutedWordMatch.containsAny($0.content, words: words) }
    }
}

import Foundation

/// Whether a stored DM adds to its conversation's unread count. On top of
/// `BlockedPeople.mayAlert` (never your own copies, never a blocked sender),
/// a message into the thread that is open on screen is read as it arrives:
/// counting it left the badge up after you had read it in the thread.
/// The app in the background does not count as on screen.
enum DMUnreadRule {
    static func countsAsUnread(mayAlert: Bool, conversation: String, visibleConversation: String?,
                               appInForeground: Bool) -> Bool {
        guard mayAlert else { return false }
        return !(appInForeground && visibleConversation == conversation)
    }
}

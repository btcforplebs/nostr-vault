import Foundation

/// The Vault tab's red dot (BottomTabBar): something came in from others, or
/// a direct message arrived. Opening the Vault list or the Vault Dashboard
/// sees it (Logen, 2026-11-12: the dashboard too, not only the list).
///
/// Unread DMs stay unread when the dashboard opens: the dot keeps the count
/// it showed there (`dmUnreadSeen`) and lights again only for more.
enum VaultNewsDot {
    static func isShown(newActivity: Bool, dmUnread: Int, dmUnreadSeen: Int) -> Bool {
        newActivity || dmUnread > dmUnreadSeen
    }

    /// The seen count after the unread count moved: reading DMs lowers it,
    /// so the next new one lights the dot; a new one never raises it.
    static func seen(_ seen: Int, afterUnread unread: Int) -> Int {
        min(seen, unread)
    }
}

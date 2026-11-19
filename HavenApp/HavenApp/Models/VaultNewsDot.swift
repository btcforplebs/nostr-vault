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

    /// The seen count is kept per account across launches: unread DMs are per
    /// device, and one never read on this device (read on the phone, say)
    /// lit the dot again after every launch (Logen 2026-11-19, iPad).
    static func seenKey(account: String) -> String { "vaultNewsDmSeen.\(account.lowercased())" }

    static func savedSeen(account: String, in defaults: UserDefaults = .standard) -> Int {
        account.isEmpty ? 0 : max(0, defaults.integer(forKey: seenKey(account: account)))
    }

    static func saveSeen(_ seen: Int, account: String, in defaults: UserDefaults = .standard) {
        guard !account.isEmpty else { return }
        defaults.set(seen, forKey: seenKey(account: account))
    }
}

import Foundation

extension AccountUnread.ListRules {
    /// The rules the Vault list applies right now, for every account on the
    /// device: Zaps Only, each account's blocks, and each account's web
    /// (`FeedService.trustedPubkeys(for:)`).
    @MainActor
    static func vaultList() -> Self {
        let config = ConfigService.shared
        let whitelist = config.whitelistedHexPubkeys
        // Read here, on the main actor: the open account's web and the pooled
        // one every other account on the device is judged by.
        let feed = FeedService.shared
        let active = config.activeAccountHexPubkey.lowercased()
        let openWeb = feed.trustedPubkeys(for: active)  // loads the saved graph if not yet
        let pooledWeb = feed.wotPubkeys
        func trusted(for recipient: String) -> Set<String> {
            AccountWeb.trusted(forRecipient: recipient, active: active, open: { openWeb }, pooled: pooledWeb)
        }
        var blocks: [String: Set<String>] = [:]
        func blocked(for recipient: String) -> Set<String> {
            if let known = blocks[recipient] { return known }
            // As LocalNotificationService.resolveNpub: only accounts on this device.
            let npub = config.allAccountNpubs.first { Bech32.decode($0)?.hexString.lowercased() == recipient }
            let set = npub.map { config.blockedHexPubkeys(forAccount: $0) } ?? []
            blocks[recipient] = set
            return set
        }
        let accounts = config.allAccountHexes
        let notifyOwn = config.config.notifyOwnAccountTags
        return Self(
            zapsOnly: config.config.zapsOnlyMode,
            isBlocked: { recipient, author in blocked(for: recipient).contains(author) },
            isOutside: { recipient, author in
                ContentFilter.isOutside(author: author, owner: recipient, whitelist: whitelist, trusted: trusted(for: recipient))
            },
            isOwnAccountTag: { recipient, author in
                NotificationPolicy.hidesOwnAccountTag(author: author, recipient: recipient,
                                                      accounts: accounts, notify: notifyOwn)
            }
        )
    }
}

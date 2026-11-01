import Foundation

extension AccountUnread.ListRules {
    /// The rules the Vault list applies right now, for every account on the
    /// device: Zaps Only, each account's blocks, and the shared web.
    @MainActor
    static func vaultList() -> Self {
        let config = ConfigService.shared
        let whitelist = config.whitelistedHexPubkeys
        let trusted = FeedService.shared.relayTabTrustedPubkeys()
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
                ContentFilter.isOutside(author: author, owner: recipient, whitelist: whitelist, trusted: trusted)
            },
            isOwnAccountTag: { recipient, author in
                NotificationPolicy.hidesOwnAccountTag(author: author, recipient: recipient,
                                                      accounts: accounts, notify: notifyOwn)
            }
        )
    }
}

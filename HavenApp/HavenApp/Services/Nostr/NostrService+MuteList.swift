import Foundation

extension NostrService {
    /// A kind 10000 (mute list) by one of this device's accounts: its public
    /// `p` tags become that account's blocks when the list is newer than the
    /// last one synced. The rest of the list (private part, words, hashtags,
    /// threads) goes to `MuteListStore`.
    func applyOwnMuteList(_ event: NostrEvent) {
        let blockedHexKeys = ProfileRepository.parseMuteListPTags(event.tags)
        let allNpubs = ConfigService.shared.allAccountNpubs
        if let matchingNpub = allNpubs.first(where: { npub in
            Bech32.decode(npub)?.hexString == event.pubkey
        }) {
            MuteListStore.shared.ingest(event)
            let blockedNpubs = ProfileRepository.hexKeysToNpubs(blockedHexKeys)
            let eventTimestamp = event.created_at
            DispatchQueue.main.async {
                let currentBlocks = ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] ?? []
                let lastSync = ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] ?? 0

                if eventTimestamp >= lastSync && Set(currentBlocks) != Set(blockedNpubs) {
                    ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] = blockedNpubs
                    ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] = eventTimestamp
                    if matchingNpub == ConfigService.shared.config.ownerNpub {
                        ConfigService.shared.config.blacklistedNpubs = blockedNpubs
                    }
                    ConfigService.shared.save()
                    #if DEBUG
                    print("NostrService: Synced \(blockedNpubs.count) blocks from Kind 10000 for \(matchingNpub.prefix(8))")
                    #endif
                    NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
                }
            }
        }
    }
}

import Foundation
#if os(iOS)
import WidgetKit
#endif

extension ConfigService {
    /// Removes one account from this device (Delete Account on its page, or
    /// a swipe in the list): its key, its signer, every per-account setting
    /// and the cache files named after it, then pushes the smaller blocked list to the relay.
    /// Both remove paths in Settings › Accounts call this, so neither can
    /// leave the account's blocks behind (see `removeAccountEntries`).
    func removeAccount(npub raw: String) {
        let npub = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !npub.isEmpty, npub != config.ownerNpub else { return }
        config.whitelistedNpubs.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == npub }
        removeBunkerConfig(forNpub: npub)
        // Switch away only after the bunker config is gone: removeBunkerConfig
        // already detaches the active signer, and its session drop must land
        // before the owner's connect, which can share the same signer session.
        if config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines) == npub {
            switchActiveAccount(to: nil)
            #if os(iOS)
            // The widgets showed this account; drop that and redraw them.
            NVSharedStore.clear()
            NVThumbnailStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
        removeCredential(forNpub: npub)
        config.removeAccountEntries(npub: npub)
        save()
        // Its caches and settings too (Delete Account sends nothing to relays).
        if let hex = Bech32.decode(npub)?.hexString {
            AppDataWipe.forgetAccount(hex: hex, npub: npub, appSupport: relayDataDir.deletingLastPathComponent())
        }
        syncBlacklistToRelay()
        NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
    }
}

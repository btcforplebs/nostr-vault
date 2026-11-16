import Foundation

extension ConfigService {
    /// Blocks `npub` privately for the active account: it goes in the
    /// encrypted part of the mute list, which only this account can open, and
    /// out of the public `p` tags if it was there. Unlike `blockProfile`
    /// nothing is stored on this device first. `blockedNpubsPerAccount` is
    /// published in the clear, so the block shows once the published list is
    /// read back, and when it can't be published the person is told it
    /// wasn't saved. Android: BlockedSettingsViewModel.blockPrivately.
    func blockPrivately(_ npub: String) {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active
        guard let hex = Bech32.decode(npub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString,
              !MuteListStore.shared.privatePubkeys(forAccount: targetNpub).contains(hex.lowercased()) else { return }
        let current = config.blockedNpubsPerAccount[targetNpub]
            ?? (targetNpub == config.ownerNpub ? config.blacklistedNpubs : [])
        NostrService.shared.publishMuteListChange(for: targetNpub, add: [npub],
                                                  localBlocks: current.filter { $0 != npub }, privately: true)
    }
}

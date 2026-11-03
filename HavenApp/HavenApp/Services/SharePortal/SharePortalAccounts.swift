import Foundation

/// Writes the share extension's "post as" list (NVShareAccountsSnapshot):
/// every account on the device with its name and picture. Called when the
/// app comes forward; the snapshot skips identical rewrites.
@MainActor
enum SharePortalAccounts {
    static func publish() {
        let config = ConfigService.shared
        guard config.config.hasCompletedSetup else { return }
        let profiles = NostrService.shared.profiles
        let accounts = config.allAccountNpubs.map { npub -> NVShareAccountsSnapshot.Account in
            let profile = Bech32.decode(npub).flatMap { profiles[$0.hexString] }
            return .init(npub: npub, name: profile?.bestName ?? "", picture: profile?.pictureURL?.absoluteString)
        }
        let active = PostingAccount.resolve(active: config.config.activeAccountNpub, owner: config.config.ownerNpub)
        NVShareAccountsSnapshot(active: active, accounts: accounts).write()
    }
}

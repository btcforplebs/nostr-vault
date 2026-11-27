import Foundation

/// How many of the owner's Vaults keep the wallet (design §4 risk 4: NIP-60
/// has no seed restore, so losing every Vault copy loses the sats). This
/// device's Vault counts once the wallet event is read back from it; each
/// paired desktop Vault copies `/private` both ways (mesh copy v2), so it is
/// counted as a second place. One place gets the warning. Logen's pick: warn,
/// never refuse. Pure, so CashuWalletTests checks it.
struct CashuVaultCopies: Equatable {
    /// nil: the Vault didn't answer the read-back.
    var thisVault: Bool?
    var desktopVaults: Int

    var places: Int { thisVault == true ? 1 + desktopVaults : 0 }
    var warnOneCopy: Bool { thisVault == true && desktopVaults == 0 }

    var line: String {
        switch thisVault {
        case nil:
            return "Can't reach your Vault yet, so your wallet isn't confirmed saved."
        case false?:
            return "Your wallet isn't on your Vault yet. It will be sent when your Vault is reachable."
        case true?:
            if desktopVaults == 0 {
                return "Your wallet is kept only on this device's Vault. If you lose this device, you lose these sats. Pair a desktop Vault so it is kept in two places."
            }
            let others = desktopVaults == 1 ? "1 desktop Vault" : "\(desktopVaults) desktop Vaults"
            return "Your wallet is kept on this device's Vault and copied to \(others)."
        }
    }
}

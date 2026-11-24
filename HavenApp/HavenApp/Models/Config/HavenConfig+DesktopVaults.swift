import Foundation

extension HavenConfig {
    // MARK: - Desktop Vaults

    /// The Vault list in force: the stored one with the one-slot setting
    /// taken in (DesktopVaultsLogic.takingInSlot). The same as
    /// `desktopVaults` once ConfigService has saved it; computed here too so
    /// an edit in the old Desktop vault sync tab counts before the next save.
    var desktopVaultsInEffect: [DesktopVault] {
        DesktopVaultsLogic.takingInSlot(desktopVaults, slot: macRelayURL, taken: desktopVaultsSlot,
                                        devices: meshDevices)
    }

    /// Stores `desktopVaultsInEffect` and the slot value it took in.
    /// Changes nothing else: `macRelayURL` stays as it is (plan §3 step 5).
    mutating func takeInDesktopVaultSlot() {
        let vaults = desktopVaultsInEffect
        if vaults != desktopVaults { desktopVaults = vaults }
        if desktopVaultsSlot != macRelayURL { desktopVaultsSlot = macRelayURL }
    }

    /// Every HTTPS Vault's `wss://host`, in list order. Feed, blastr and
    /// import seed relays put these first, as they did the slot's.
    var desktopVaultWssURLs: [String] { DesktopVaultsLogic.wssURLs(desktopVaultsInEffect) }

    /// Every HTTPS Vault's `https://host`, in list order (Blossom mirrors).
    var desktopVaultHttpsURLs: [String] { DesktopVaultsLogic.httpsURLs(desktopVaultsInEffect) }
}

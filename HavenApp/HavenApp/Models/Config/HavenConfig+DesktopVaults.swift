import Foundation

extension HavenConfig {
    // MARK: - Desktop Vaults

    /// The Vault list in force: the stored one with the one-slot setting
    /// taken in (DesktopVaultsLogic.takingInSlot). The same as
    /// `desktopVaults` once ConfigService has saved it; computed here too so
    /// an edit in the old Desktop vault sync tab counts before the next save.
    ///
    /// It follows My Devices too (DesktopVaultsLogic.followingDevices), and
    /// leaves out this device's own mesh address (`ownNpub`, Tron N2), and
    /// every address deleted on Desktop Vaults (`desktopVaultsRemoved`, P4).
    var desktopVaultsInEffect: [DesktopVault] { desktopVaultsInEffect(ownNpub: Self.storedOwnMeshNpub) }

    func desktopVaultsInEffect(ownNpub: String?) -> [DesktopVault] {
        let taken = DesktopVaultsLogic.takingInSlot(desktopVaults, slot: macRelayURL, taken: desktopVaultsSlot,
                                                    devices: meshDevices, ownNpub: ownNpub)
        let following = DesktopVaultsLogic.followingDevices(taken, devices: meshDevices, slot: macRelayURL, ownNpub: ownNpub)
        return DesktopVaultsEditing.applyingRemoved(following, removed: desktopVaultsRemoved)
    }

    /// The one-slot `macRelayURL` while a Vault still has its address, else
    /// "" (DesktopVaultsEditing.slotInEffect). Everything derived from the
    /// slot reads this, so deleting its Vault on Desktop Vaults turns it off.
    var macRelayURLInEffect: String {
        DesktopVaultsEditing.slotInEffect(macRelayURL, vaults: desktopVaultsInEffect)
    }

    /// This device's own mesh npub as FipsMeshService last saw it
    /// (`FipsMeshService.ownNpubKey`); nil before the engine first ran.
    static var storedOwnMeshNpub: String? {
        UserDefaults.standard.string(forKey: "fipsMesh.ownNpub")
    }

    /// Stores `desktopVaultsInEffect` and the slot value it took in.
    /// Changes nothing else: `macRelayURL` stays as it is (plan §3 step 5).
    mutating func takeInDesktopVaultSlot(ownNpub: String? = HavenConfig.storedOwnMeshNpub) {
        let vaults = desktopVaultsInEffect(ownNpub: ownNpub)
        if vaults != desktopVaults { desktopVaults = vaults }
        if desktopVaultsSlot != macRelayURL { desktopVaultsSlot = macRelayURL }
    }

    /// Every HTTPS Vault's `wss://host`, in list order. Feed, blastr and
    /// import seed relays put these first, as they did the slot's.
    var desktopVaultWssURLs: [String] { DesktopVaultsLogic.wssURLs(desktopVaultsInEffect) }

    /// Every HTTPS Vault's `https://host`, in list order (Blossom mirrors).
    var desktopVaultHttpsURLs: [String] { DesktopVaultsLogic.httpsURLs(desktopVaultsInEffect) }

    /// The mesh npubs of the Vaults reachable over FIPS, in list order
    /// (DesktopVaultsLogic.meshNpubs): what the relay dials and where
    /// publish-for-me and mesh media go. Replaces `macRelayMeshNpub` (P3).
    var desktopVaultMeshNpubs: [String] { desktopVaultMeshNpubs(ownNpub: Self.storedOwnMeshNpub) }

    func desktopVaultMeshNpubs(ownNpub: String?) -> [String] {
        DesktopVaultsLogic.meshNpubs(desktopVaultsInEffect(ownNpub: ownNpub))
    }

    /// Every HTTPS Vault's DM inbox, in list order (iOS; a Mac lists its own).
    var desktopVaultDMInboxURLs: [String] {
        DesktopVaultsLogic.dmInboxURLs(desktopVaultsInEffect, slot: macRelayURLInEffect)
    }

    // MARK: Edits from the Desktop Vaults screens (P4)

    /// Adds `vault` at the end; its addresses leave `desktopVaultsRemoved`.
    mutating func addDesktopVault(_ vault: DesktopVault) {
        let next = DesktopVaultsEditing.inserting(vault, into: desktopVaultsInEffect, removed: desktopVaultsRemoved)
        desktopVaultsRemoved = next.removed
        desktopVaults = next.vaults
    }

    /// Deletes the Vault; its addresses go on `desktopVaultsRemoved`.
    mutating func deleteDesktopVault(id: String) {
        let next = DesktopVaultsEditing.deleting(id, from: desktopVaultsInEffect, removed: desktopVaultsRemoved)
        desktopVaultsRemoved = next.removed
        desktopVaults = next.vaults
    }

    /// Stores a new order (after a drag) or a rename.
    mutating func setDesktopVaults(_ vaults: [DesktopVault]) {
        desktopVaults = DesktopVaultsLogic.ordered(vaults)
    }

    /// Changes a Vault's web address; nil when that went, else why not.
    mutating func setDesktopVaultAddress(id: String, to typed: String) -> String? {
        switch DesktopVaultsEditing.changingAddress(of: id, to: typed, in: desktopVaultsInEffect,
                                                    removed: desktopVaultsRemoved) {
        case .success(let next):
            desktopVaultsRemoved = next.removed
            desktopVaults = next.vaults
            return nil
        case .failure(let refusal):
            return refusal.message
        }
    }

    /// Pairing a device again undoes an earlier delete of its Vault.
    mutating func forgetRemovedDesktopVault(meshNpub: String) {
        desktopVaultsRemoved.removeAll { $0 == DesktopVaultsEditing.removedKey(meshNpub: meshNpub) }
    }
}

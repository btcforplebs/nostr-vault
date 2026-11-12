import Foundation

/// Pure rules for Settings › Your Devices, kept out of the view for tests.
enum YourDevicesLogic {
    /// Which Sync now a device's card gets.
    enum SyncAction: Equatable {
        /// The desktop vault's sync check (the Mac slot's copy and check).
        case desktopVault
        /// Send what waits for the mobile vault.
        case mobileVault
    }

    /// A desktop vault gets the sync check only while the phone has a Mac set
    /// (the check runs against that Mac); a mobile vault only when it is the
    /// one this phone sends to. Phones and browser vaults get none.
    static func syncAction(_ device: MeshDevice, macSet: Bool, homeVaultNpub: String?) -> SyncAction? {
        switch device.role {
        case .mac: return macSet ? .desktopVault : nil
        case .homeVault: return device.npub == homeVaultNpub ? .mobileVault : nil
        case .phone, .browser: return nil
        }
    }

    /// The card's second line: its role, and whether this device is
    /// connected to it now. `peers` nil: the mesh is not running, so only
    /// the role is known.
    static func statusLine(_ device: MeshDevice, peers: Set<String>?) -> String {
        guard let peers else { return device.role.label }
        return peers.contains(device.npub)
            ? "\(device.role.label) · in reach"
            : "\(device.role.label) · not in reach now"
    }
}

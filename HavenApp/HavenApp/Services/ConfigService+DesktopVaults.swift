import Foundation

extension ConfigService {
    /// One edit from the Desktop Vaults screens (P4): change the Vault list,
    /// save, and hand the relay its new MAC_RELAY_URL / DESKTOP_VAULT_URLS
    /// (it restarts only when those changed). Nothing is published here; a
    /// list switch goes through DesktopVaultListEdit.
    @MainActor
    func editDesktopVaults(_ edit: (inout HavenConfig) -> Void) {
        edit(&config)
        config.takeInDesktopVaultSlot()
        save()
        RelayProcessManager.shared.applySavedConfig(config)
    }
}

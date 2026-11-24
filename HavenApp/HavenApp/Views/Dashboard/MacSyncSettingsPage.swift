import SwiftUI

/// Settings › Desktop Vaults on a phone (DesktopVaultsSettingsView), or one
/// Vault's page when `vaultID` is set (a Your Devices desktop row); on a Mac,
/// this vault's own web address.
struct MacSyncSettingsPage: View {
    var vaultID: String?

    var body: some View {
        #if os(iOS)
        if let vaultID {
            DesktopVaultDetailView(vaultID: vaultID)
        } else {
            DesktopVaultsSettingsView()
        }
        #else
        MacRelayDomainSettingsView()
        #endif
    }
}

#if os(macOS)
import SwiftUI

/// Vault Dashboard › Advanced, Mac only: the Mac relay console's Open Browser
/// button, and links to the Mac-only vault settings that stay in Settings
/// (relay address and port, public on the web, startup, vault folder), so the
/// one Vault reaches everything the Relay rail item did.
struct MacVaultAdvancedRows: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        DashboardRow(
            icon: "safari",
            title: "Open in browser",
            detail: "Your vault's own web page, at \(configService.config.webURL).",
            state: .info
        ) {
            RowButton(title: "Open") {
                if let url = URL(string: configService.config.webURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        DashboardDivider()
        SettingLink(icon: "network", title: "Relay address and port", value: ":\(configService.config.relayPort)") {
            MacRelayDomainSettingsView().settingsPage("Relay address")
        }
        DashboardDivider()
        SettingLink(icon: "globe", title: "Public on the web", value: nil) {
            PublicOnWebSettingsView().settingsPage("Public on the web")
        }
        DashboardDivider()
        SettingLink(icon: "power", title: "Startup", value: nil) {
            StartupSettingsView().settingsPage("Startup")
        }
        DashboardDivider()
        SettingLink(icon: "folder", title: "Vault folder", value: nil) {
            AdvancedSettingsView().settingsPage("Advanced")
        }
    }
}
#endif

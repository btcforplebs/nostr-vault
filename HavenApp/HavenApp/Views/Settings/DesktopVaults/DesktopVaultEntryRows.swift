import SwiftUI

#if os(iOS)
/// "From your Vault <name>": the desktop Vault entries of the published lists,
/// read only, on Settings › Relays (relays and DM inbox) and Media Servers
/// (Desktop Vaults P4, §2.4). Each opens its Vault's page, where its switches
/// add or remove them; a Save on these pages carries them through as they are.
/// Android twin: `DesktopVaultEntryRows.kt` (P7).
struct DesktopVaultEntryRows: View {
    var relays: [[String]] = []
    var inboxes: [String] = []
    var servers: [String] = []
    @EnvironmentObject var configService: ConfigService

    private var entries: [(entry: DesktopVaultsEditing.ListedEntry, list: String)] {
        let vaults = configService.config.desktopVaultsInEffect
        let r = DesktopVaultsEditing.listedEntries(relays, in: .relays, vaults: vaults).map { ($0, "Relay") }
        let i = DesktopVaultsEditing.listedEntries(inboxes.map { ["relay", $0] }, in: .inbox, vaults: vaults)
            .map { ($0, "DM inbox") }
        let m = DesktopVaultsEditing.listedEntries(servers.map { ["server", $0] }, in: .media, vaults: vaults)
            .map { ($0, $0.mesh ? "Media over the Mesh · Beta" : "Media server") }
        return r + i + m
    }

    var body: some View {
        let entries = entries
        if !entries.isEmpty {
            Section {
                ForEach(entries, id: \.entry.id) { item in
                    NavigationLink {
                        DesktopVaultDetailView(vaultID: item.entry.vault.id)
                            .settingsPage(item.entry.vault.displayName)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: DesktopVaultText.icon(item.entry.vault.kind))
                                .foregroundColor(.teal)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("From your Vault \(item.entry.vault.displayName)")
                                    .font(.appSubheadline)
                                Text("\(item.list) · \(item.entry.url)")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            } header: {
                Text("From your desktop Vaults")
            } footer: {
                Text("Set on each Vault's page under Listed publicly. Saving here keeps them as they are.")
            }
        }
    }
}
#endif

import SwiftUI

#if os(iOS)
/// Settings › Desktop Vaults (Desktop Vaults P4, PLANS/NV_DESKTOP_VAULTS_PLAN.md
/// §2.7): every desktop Vault, in order, with Add. Dragging sets the order of
/// the Vault entries in the public lists (§2.5 rule 2): only the lists whose
/// Vault entries move are republished. Replaces the one-slot Desktop vault
/// sync tab (MacRelaySettingsView). Android twin: `DesktopVaultsScreen.kt` (P7).
struct DesktopVaultsSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var showAdd = false
    /// What the last drag's republish said, when it didn't all go out.
    @State private var orderLine: String?

    private var vaults: [DesktopVault] { configService.config.desktopVaultsInEffect }

    var body: some View {
        let vaults = vaults
        List {
            Section {
                if vaults.isEmpty {
                    Text("No desktop Vaults yet. A desktop Vault is a Mac or a Linux box that keeps a copy of your vault, always on.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                ForEach(vaults) { vault in
                    NavigationLink {
                        DesktopVaultDetailView(vaultID: vault.id)
                            .settingsPage(vault.displayName)
                    } label: {
                        DesktopVaultRow(vault: vault)
                    }
                }
                .onMove(perform: move)
            } header: {
                Text("Your desktop Vaults")
            } footer: {
                if vaults.count > 1 {
                    Text(orderLine ?? "Drag to set the order. The first Vault comes first in your public lists, and other apps upload your media to the first media server.")
                        .foregroundColor(orderLine == nil ? .secondary : .orange)
                }
            }
            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("Add a desktop Vault", systemImage: "plus.circle")
                }
            } footer: {
                Text("Pair it over the Mesh, type its web address, or both. Drafts and private files go over the Mesh only.")
            }
            if !vaults.isEmpty {
                Section {
                    MacRelaySyncStatusView()
                } header: {
                    Text("Sync")
                }
            }
        }
        .warmFormBackground()
        .listStyle(.insetGrouped)
        .toolbar {
            if vaults.count > 1 { EditButton() }
        }
        .sheet(isPresented: $showAdd) {
            AddDesktopVaultSheet().environmentObject(configService)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        let moved = DesktopVaultsEditing.moving(vaults, from: source, to: destination)
        guard moved.map(\.id) != vaults.map(\.id) else { return }
        configService.editDesktopVaults { $0.setDesktopVaults(moved) }
        orderLine = nil
        DesktopVaultListEdit.reorder(vaults: moved) { line in
            orderLine = line.map { "Order saved here, but a list wasn't changed: \($0)" }
        }
    }
}

/// One Vault in the list: its name, kind and how it is reached.
private struct DesktopVaultRow: View {
    let vault: DesktopVault

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DesktopVaultText.icon(vault.kind))
                .font(.appSystem(size: 18))
                .foregroundColor(.teal)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.displayName)
                    .font(.appSubheadline)
                Text(DesktopVaultText.paths(vault))
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

#endif

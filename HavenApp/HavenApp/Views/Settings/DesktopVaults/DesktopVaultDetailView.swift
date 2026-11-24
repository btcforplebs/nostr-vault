import SwiftUI

#if os(iOS)
/// Settings › Desktop Vaults › one Vault (Desktop Vaults P4, §2.7): its name,
/// how it is reached (Mesh, web or both), its last copy, which public lists
/// name it (DesktopVaultListedSection) and Delete, which asks whether to take
/// it out of those lists too (§2.5 rule 5). Android twin:
/// `DesktopVaultDetailScreen.kt` (P7).
struct DesktopVaultDetailView: View {
    let vaultID: String
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var addressLine: String?
    /// The newest published lists, read when the page opens. A list missing
    /// here didn't load: its switches stay off limits.
    @State private var lists: [DesktopVaultList: [[String]]] = [:]
    @State private var loading = true
    @State private var askDelete = false
    @State private var deleting = false
    @State private var deleteLine: String?
    @State private var showPair = false

    private var vault: DesktopVault? {
        configService.config.desktopVaultsInEffect.first { $0.id == vaultID }
    }

    var body: some View {
        Group {
            if let vault {
                form(vault)
            } else {
                Text("This Vault was deleted.")
                    .foregroundColor(.secondary)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showPair) { PairDeviceView().environmentObject(configService) }
    }

    private func form(_ vault: DesktopVault) -> some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { rename(vault) }
                LabeledContent("Kind", value: DesktopVaultText.kindLabel(vault.kind))
            } header: {
                Text("Name")
            }
            pathsSection(vault)
            if let line = statusLine(vault) {
                Section {
                    Text(line).font(.appCaption).foregroundColor(.secondary)
                } header: {
                    Text("Last copy")
                }
            }
            DesktopVaultListedSection(vault: vault, lists: $lists, loading: loading)
            Section {
                Button(role: .destructive) {
                    askDelete = true
                } label: {
                    if deleting {
                        HStack { ProgressView(); Text("Taking it out of your lists…") }
                    } else {
                        Text("Delete this Vault")
                    }
                }
                .disabled(deleting)
            } footer: {
                if let deleteLine {
                    Text(deleteLine).foregroundColor(.orange)
                } else {
                    Text("This phone stops syncing with it. It stays in Your Devices until you remove it there.")
                }
            }
        }
        .warmFormBackground()
        .groupedFormStyleCompat()
        .onAppear {
            name = vault.name
            address = vault.httpsURL ?? ""
        }
        .onDisappear { rename(vault) }
        .confirmationDialog("Also take \(vault.displayName) out of your public lists?",
                            isPresented: $askDelete, titleVisibility: .visible) {
            Button("Yes, take it out") { delete(vault, unlist: true) }
            Button("No, leave my lists as they are") { delete(vault, unlist: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Yes removes its addresses from your relays, DM inbox and media servers. No leaves them there as ordinary entries.")
        }
    }

    // MARK: Paths

    private func pathsSection(_ vault: DesktopVault) -> some View {
        Section {
            HStack {
                Label("Mesh", systemImage: "point.3.filled.connected.trianglepath.dotted")
                Spacer()
                if let npub = vault.meshNpub {
                    Text(MeshPairing.shortAddress(npub))
                        .font(.appSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Button("Pair over the Mesh") { showPair = true }
                        .buttonStyle(.borderless)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Web address", systemImage: "globe")
                HStack {
                    TextField("https://vault.example.com", text: $address)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disabled(listedOnWeb(vault))
                    if address != (vault.httpsURL ?? "") {
                        Button("Save") { saveAddress(vault) }
                            .buttonStyle(.borderless)
                    }
                }
                if let addressLine {
                    Text(addressLine).font(.appCaption).foregroundColor(.orange)
                } else if listedOnWeb(vault) {
                    Text("Turn its public lists off below first to change the address.")
                        .font(.appCaption).foregroundColor(.secondary)
                }
            }
        } header: {
            Text("How it's reached")
        } footer: {
            if vault.meshNpub == nil {
                Text(DesktopVaultText.webOnlyNote)
            } else if vault.httpsURL == nil {
                Text("Everything goes over the Mesh, including drafts and private files.")
            } else {
                Text("The Mesh comes first, the web address is the fallback. Drafts and private files go over the Mesh only.")
            }
        }
    }

    /// Whether any web list names its host now: its address can't change
    /// under a listed entry.
    private func listedOnWeb(_ vault: DesktopVault) -> Bool {
        DesktopVaultList.allCases.contains { list in
            lists[list].map { DesktopVaultsLists.isListed(vault, path: .web, in: list, tags: $0) } ?? false
        }
    }

    private func statusLine(_ vault: DesktopVault) -> String? {
        guard let https = vault.httpsURL else { return nil }
        let url = "wss://" + DesktopVaultsLogic.base(https)
        let status = RelayConfiguration.macSyncStatus(under: configService.relayDataDir, vaultURL: url)
        return RelayConfiguration.macSyncRowDetail(status, macURL: url) {
            $0.formatted(.relative(presentation: .named))
        }
    }

    // MARK: Edits

    private func rename(_ vault: DesktopVault) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != vault.name else { return }
        let renamed = DesktopVaultsEditing.renaming(vault.id, to: trimmed, in: configService.config.desktopVaultsInEffect)
        configService.editDesktopVaults { $0.setDesktopVaults(renamed) }
    }

    private func saveAddress(_ vault: DesktopVault) {
        var line: String?
        configService.editDesktopVaults { line = $0.setDesktopVaultAddress(id: vault.id, to: address) }
        addressLine = line
        if line == nil { address = self.vault?.httpsURL ?? "" }
    }

    private func delete(_ vault: DesktopVault, unlist: Bool) {
        deleteLine = nil
        guard unlist else {
            removeHere(vault)
            return
        }
        deleting = true
        DesktopVaultListEdit.remove(vault) { outcome in
            deleting = false
            switch outcome {
            case .published, .unchanged:
                removeHere(vault)
            default:
                deleteLine = (outcome.message ?? DesktopVaultListEdit.notLoadedMessage) + " The Vault was not deleted."
            }
        }
    }

    private func removeHere(_ vault: DesktopVault) {
        configService.editDesktopVaults { $0.deleteDesktopVault(id: vault.id) }
        dismiss()
    }

    private func load() async {
        loading = true
        for list in DesktopVaultList.allCases {
            if let tags = await DesktopVaultListEdit.current(list) { lists[list] = tags }
        }
        loading = false
    }
}
#endif

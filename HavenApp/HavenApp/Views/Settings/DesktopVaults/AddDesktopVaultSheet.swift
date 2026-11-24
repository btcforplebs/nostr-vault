import SwiftUI

#if os(iOS)
/// Desktop Vaults › Add (Desktop Vaults P4, §2.7): pair it over the Mesh,
/// type its web address, or both. A newly paired Mac or Linux box joins the
/// list by itself (DesktopVaultsLogic.followingDevices), so Pair just opens
/// the two-scan pairing; a paired desktop whose Vault was deleted can be
/// picked again here. A host another Vault has is refused (§2.5 rule 4).
/// Nothing is published: list switches are on the Vault's own page, off.
/// Android twin: `AddDesktopVaultSheet.kt` (P7).
struct AddDesktopVaultSheet: View {
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: DesktopVaultKind = .mac
    @State private var address = ""
    @State private var meshNpub: String?
    @State private var refusal: String?
    @State private var showPair = false

    /// Paired desktops that are not a Vault now (their Vault was deleted).
    private var pairedLeftOut: [MeshDevice] {
        let vaults = configService.config.desktopVaultsInEffect
        return FipsMeshDevices.current(configService.config).filter { device in
            device.role == .mac && !vaults.contains { $0.meshNpub == device.npub }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showPair = true
                    } label: {
                        Label("Pair a new desktop over the Mesh", systemImage: "qrcode.viewfinder")
                    }
                    if !pairedLeftOut.isEmpty {
                        Picker("Paired desktop", selection: $meshNpub) {
                            Text("None").tag(String?.none)
                            ForEach(pairedLeftOut) { device in
                                Text(device.displayName).tag(Optional(device.npub))
                            }
                        }
                    }
                } header: {
                    Text("Over the Mesh")
                } footer: {
                    Text("A desktop you pair joins your Vaults by itself. Drafts and private files go over the Mesh only.")
                }
                Section {
                    TextField("https://vault.example.com", text: $address)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Web address")
                } footer: {
                    Text(meshNpub == nil ? DesktopVaultText.webOnlyNote
                                         : "With both, the Mesh comes first and the web address is the fallback.")
                }
                Section {
                    TextField("Name", text: $name)
                    Picker("Kind", selection: $kind) {
                        ForEach(DesktopVaultKind.allCases, id: \.self) { kind in
                            Text(DesktopVaultText.kindLabel(kind)).tag(kind)
                        }
                    }
                } header: {
                    Text("Name")
                } footer: {
                    if let refusal {
                        Text(refusal).foregroundColor(.orange)
                    }
                }
            }
            .warmFormBackground()
            .groupedFormStyleCompat()
            .navigationTitle("Add a desktop Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty && meshNpub == nil)
                }
            }
            .onChange(of: meshNpub) { _, npub in
                if name.isEmpty, let device = pairedLeftOut.first(where: { $0.npub == npub }) { name = device.name }
            }
            .sheet(isPresented: $showPair) {
                PairDeviceView().environmentObject(configService)
            }
        }
    }

    private func add() {
        let vaults = configService.config.desktopVaultsInEffect
        switch DesktopVaultsEditing.adding(name: name, httpsTyped: address, meshNpub: meshNpub, kind: kind,
                                           to: vaults, ownNpub: HavenConfig.storedOwnMeshNpub) {
        case .failure(let why):
            refusal = why.message
        case .success(let vault):
            configService.editDesktopVaults { $0.addDesktopVault(vault) }
            dismiss()
        }
    }
}
#endif

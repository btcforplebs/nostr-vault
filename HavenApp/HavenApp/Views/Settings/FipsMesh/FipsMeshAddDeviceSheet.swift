import SwiftUI

#if os(iOS)
/// Add any of your devices by its mesh address: scan or paste it, then say
/// what it is. One flow for the Mac, a phone, a home vault and a browser page.
struct FipsMeshAddDeviceSheet: View {
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var nostr = NostrService.shared
    @State private var address = ""
    @State private var name = ""
    @State private var role: MeshDeviceRole = .mac
    @State private var showScanner = false
    @State private var error: String?

    /// Kiosk phones already in the owner's 10063, offered as one-tap picks.
    private var listedVaults: [String] {
        let known = Set(FipsMeshDevices.current(configService.config).map(\.npub))
        return HomeVaultSender.meshEntries(serverList: nostr.serverLists[nostr.activeHexPubkey] ?? [])
            .filter { !known.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan its QR code", systemImage: "qrcode.viewfinder").font(.appBody)
                    }
                    TextField("npub1… mesh address", text: $address)
                        .font(.appSystem(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !address.isEmpty, HomeVaultLogic.meshNpub(fromInput: address) == nil {
                        Text("That isn't a mesh address yet.")
                            .font(.appCaption)
                            .foregroundColor(.orange)
                    }
                    ForEach(listedVaults, id: \.self) { npub in
                        Button {
                            address = npub
                            role = .homeVault
                        } label: {
                            Label("In your media servers: \(npub.prefix(12))…\(npub.suffix(6))", systemImage: "house")
                                .font(.appCaption)
                        }
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text("Open Mesh on the other device and copy the address under This Device.")
                }

                Section {
                    Picker("This is", selection: $role) {
                        ForEach(MeshDeviceRole.allCases) { role in
                            Label(role.label, systemImage: role.icon).tag(role)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("This Is")
                } footer: {
                    Text(role.job)
                }

                Section {
                    TextField("Name (optional)", text: $name)
                } footer: {
                    if let error {
                        Text(error).foregroundColor(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .tint(Color.havenPurple)
            .navigationTitle("Add a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(HomeVaultLogic.meshNpub(fromInput: address) == nil)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView(
                    title: "Scan the device's mesh address",
                    validate: { HomeVaultLogic.meshNpub(fromInput: $0) == nil ? "That QR code is not a mesh address" : nil }
                ) { code in
                    showScanner = false
                    address = code
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func add() {
        error = FipsMeshDevices.add(address: address, name: name, role: role, config: configService)
        if error == nil { dismiss() }
    }
}
#endif

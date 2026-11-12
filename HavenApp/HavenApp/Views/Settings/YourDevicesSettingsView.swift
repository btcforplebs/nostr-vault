import SwiftUI

/// Settings › Your Devices: the devices you linked with two scans, Sync now
/// for your vaults, Connect a computer or phone, and on a phone the switch
/// that makes it an always-on vault. The mesh plumbing and the desktop
/// vault's web address sit under Advanced, so nobody has to know about them
/// to connect a vault (Logen 2026-11-12). Android: YourDevicesScreen.kt.
struct YourDevicesSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var showPair = false
    #if os(iOS)
    @ObservedObject private var mesh = FipsMeshService.shared
    @ObservedObject private var homeVault = HomeVaultSender.shared
    #else
    @ObservedObject private var mesh = MacFipsMeshService.shared
    #endif

    var body: some View {
        content
            .sheet(isPresented: $showPair) {
                PairDeviceView().environmentObject(configService)
            }
    }

    /// Pairing needs the mesh: turn it on first, as the Mesh switch does.
    private func connect() {
        #if os(iOS)
        if !FipsMeshSettings.enabled { mesh.setEnabled(true) }
        #else
        if !mesh.enabled { mesh.setEnabled(true) }
        #endif
        showPair = true
    }

    static let connectFooter = "Two scans: one shows a code, the other scans it. Your Nostr key never leaves this device."

    #if os(iOS)
    private var devices: [MeshDevice] { FipsMeshDevices.current(configService.config) }

    private var content: some View {
        List {
            devicesSection
            Section {
                Button(action: connect) {
                    Label("Connect a computer or phone", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text(Self.connectFooter)
            }
            YourDevicesThisPhoneSection()
            Section {
                NavigationLink("Mesh") { FipsMeshSettingsView().settingsPage("Mesh") }
                NavigationLink("Desktop vault by web address") {
                    MacRelaySettingsView().settingsPage("Desktop vault by web address")
                }
            } header: {
                Text("Advanced")
            }
        }
        .listStyle(.insetGrouped)
        .tint(Color.havenPurple)
        .onAppear { mesh.refresh() }
    }

    private var devicesSection: some View {
        Section {
            if devices.isEmpty {
                Text("No devices yet.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            ForEach(devices) { device in
                NavigationLink {
                    FipsMeshDeviceView(npub: device.npub)
                } label: {
                    YourDeviceCard(device: device, status: YourDevicesLogic.statusLine(device, peers: peers))
                }
                syncRow(device)
            }
        } header: {
            Text("Your devices")
        }
    }

    private var peers: Set<String>? {
        guard mesh.status?.running == true else { return nil }
        return Set(mesh.status?.peers ?? [])
    }

    /// The mobile vault this phone sends to, for the account in use.
    private var ownHomeVaultNpub: String? {
        guard let vault = homeVault.homeVault, vault.ownerHex == NostrService.shared.activeHexPubkey else { return nil }
        return vault.meshNpub
    }

    /// A vault's Sync now: the desktop vault's sync check, or sending what
    /// waits for the mobile vault. Phones and browser vaults have none.
    @ViewBuilder
    private func syncRow(_ device: MeshDevice) -> some View {
        switch YourDevicesLogic.syncAction(device, macSet: !RelayConfiguration.macRelayURL(config: configService.config).isEmpty,
                                          homeVaultNpub: ownHomeVaultNpub) {
        case .desktopVault:
            MacRelaySyncStatusView()
        case .mobileVault:
            HStack {
                Text(homeVault.queue.isEmpty ? "Nothing waiting" : "\(homeVault.queue.count) waiting until it's in reach")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                Spacer()
                if homeVault.sending {
                    ProgressView()
                } else {
                    Button("Sync now") { Task { await homeVault.drain(userInitiated: true) } }
                        .font(.appCaption)
                        .buttonStyle(.borderless)
                        .disabled(homeVault.queue.isEmpty)
                }
            }
        case nil:
            EmptyView()
        }
    }
    #else
    private var devices: [MeshDevice] {
        configService.config.meshDevices.filter { $0.npub != mesh.ownNpub }
    }

    private var content: some View {
        Form {
            Section {
                if devices.isEmpty {
                    Text("No devices yet.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                ForEach(devices) { device in
                    YourDeviceCard(device: device, status: device.role.label)
                }
                Button(action: connect) {
                    Label("Connect a phone", systemImage: "qrcode")
                }
            } header: {
                Text("Your devices")
            } footer: {
                Text(Self.connectFooter + " Rename or remove a device under Mesh, below.")
            }
        }
        .groupedFormStyleCompat()
        .onAppear { mesh.loadOwnNpub() }
    }
    #endif
}

/// One device: what it is, its name, and how it is doing.
struct YourDeviceCard: View {
    let device: MeshDevice
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.role.icon)
                .font(.appSystem(size: 20))
                .foregroundColor(.havenPurple)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.appBody)
                Text(status)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

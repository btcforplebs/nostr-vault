import SwiftUI

#if os(iOS)
/// Every FIPS mesh setting on one page, in the order someone needs them: is it
/// on, who am I, what are my devices, are they in sync, who else may look, and
/// the plumbing last. Same sections and labels on iPhone, Android and Mac.
struct FipsMeshSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var mesh = FipsMeshService.shared
    @ObservedObject private var homeVault = HomeVaultSender.shared
    @ObservedObject private var browser = BrowserRelaySender.shared
    @State private var enabled = FipsMeshSettings.enabled

    private var devices: [MeshDevice] { FipsMeshDevices.current(configService.config) }

    var body: some View {
        List {
            meshSection
            FipsMeshThisDeviceSection()
            FipsMeshMyDevicesSection(devices: devices)
            syncSection
            FipsMeshShareSection()
            advancedSection
        }
        .listStyle(.insetGrouped)
        .tint(Color.havenPurple)
        .navigationTitle("FIPS Mesh")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { mesh.refresh() }
    }

    // MARK: 1 Mesh

    private var meshSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { on in
                    enabled = on
                    mesh.setEnabled(on)
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mesh").font(.appBody)
                    statusLine
                }
            }
            .tint(Color.havenPurple)
        } footer: {
            Text(enabled
                 ? "Your devices reach each other over the FIPS mesh, with no public IP or domain."
                 : "Turn the mesh on to reach your Mac, your home vault and your browser page from this phone.")
        }
    }

    private var statusLine: some View {
        let running = mesh.status?.running == true
        let inReach = MeshDevicesLogic.inReachCount(devices, peers: Set(mesh.status?.peers ?? []))
        return HStack(spacing: 6) {
            Circle()
                .fill(!enabled ? Color.gray : running ? Color.havenOnline : Color.yellow)
                .frame(width: 8, height: 8)
            Text(MeshDevicesLogic.statusLine(enabled: enabled, running: running, inReach: inReach, total: devices.count))
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 4 Sync

    @ViewBuilder
    private var syncSection: some View {
        let hasMac = !configService.config.macRelayWssURL.isEmpty || configService.config.macRelayMeshNpub != nil
        let owner = NostrService.shared.activeHexPubkey
        let hasHomeVault = homeVault.homeVault?.ownerHex == owner
        Section {
            if hasMac {
                MacRelaySyncStatusView()
            }
            if hasHomeVault {
                HStack {
                    Text(homeVault.queue.isEmpty ? "Home vault: nothing waiting" : "Home vault: \(homeVault.queue.count) waiting until it's in reach")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if homeVault.sending {
                        ProgressView()
                    } else if !homeVault.queue.isEmpty {
                        Button("Send now") { Task { await homeVault.drain(userInitiated: true) } }
                            .font(.appCaption)
                    }
                }
            }
            if !hasMac && !hasHomeVault {
                Text("Add your Mac or a home vault under My Devices to sync with it.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Sync")
        }
    }

    // MARK: 6 Advanced

    private var advancedSection: some View {
        Section {
            NavigationLink {
                FipsMeshAdvancedView()
            } label: {
                HStack {
                    Text("Advanced").font(.appBody)
                    Spacer()
                    Text("Finder relays, middle server")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
#endif

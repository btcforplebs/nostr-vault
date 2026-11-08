import SwiftUI

#if os(macOS)
/// FIPS Mesh on the Mac: the same sections, in the same order, as the iPhone
/// page. Mesh is the switch for the app's own engine (MacFipsMeshService),
/// open to My Devices only. Share With Others and Advanced still list a FIPS
/// transport such as nostr-vpn, which the engine does not replace.
struct MacFipsMeshSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var mesh = MacFipsMeshService.shared
    @StateObject private var detection = FIPSDetectionService()
    @State private var showPair = false
    @State private var copied = false
    /// The device Remove asked about, until it is confirmed or cancelled.
    @State private var removing: MeshDevice?

    var body: some View {
        Form {
            meshSection
            thisDeviceSection
            myDevicesSection
            syncSection
            shareSection
            advancedSection
        }
        .groupedFormStyleCompat()
        .sheet(isPresented: $showPair) { PairDeviceView().environmentObject(configService) }
        .onAppear {
            detection.startPolling()
            mesh.loadOwnNpub()
        }
        .onDisappear { detection.stopPolling() }
    }

    // MARK: 1 Mesh

    private var meshSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { mesh.enabled },
                set: { mesh.setEnabled($0) }
            )) {
                Text("Mesh").font(.appBody)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let error = mesh.lastError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("Mesh")
        } footer: {
            Text("Your devices reach this vault over the mesh, with no public IP or domain. Anyone else can only open photos and files by their link, at up to 1 MB/s. They can't read your notes or change anything.")
        }
    }

    private var statusColor: Color {
        if mesh.running { return .havenOnline }
        if mesh.starting { return .yellow }
        return .gray
    }

    /// The iPhone's status line (MeshDevicesLogic.statusLine): how many of
    /// My Devices the running engine is connected to.
    private var statusText: String {
        let devices = configService.config.meshDevices.filter { $0.npub != mesh.ownNpub }
        return MeshDevicesLogic.macStatusLine(enabled: mesh.enabled, running: mesh.running, starting: mesh.starting,
                                              inReach: MeshDevicesLogic.inReachCount(devices, peers: peers),
                                              total: devices.count)
    }

    /// Who the engine is connected to now; empty while it is not running.
    private var peers: Set<String> {
        mesh.running ? Set(mesh.status?.peers ?? []) : []
    }

    // MARK: 2 This Device

    private var thisDeviceSection: some View {
        Section {
            if let npub = mesh.ownNpub {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mesh address")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text(npub)
                        .font(.appSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Reading this Mac's mesh address…")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            Button {
                showPair = true
            } label: {
                Label("Link a device", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("This Device")
        } footer: {
            Text("Link your phone or iPad with two scans. For something that can't scan, copy this address under Advanced.")
        }
    }

    // MARK: 3 My Devices

    private var myDevicesSection: some View {
        Section {
            ForEach(configService.config.meshDevices) { device in
                HStack(spacing: 10) {
                    Image(systemName: device.role.icon)
                        .foregroundColor(.teal)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName).font(.appBody)
                        Text("\(device.role.label) · \(device.npub.prefix(12))…\(device.npub.suffix(6))")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        // The iPhone's in-reach dot (FipsMeshDeviceRow), while the engine runs.
                        if mesh.running {
                            let inReach = peers.contains(device.npub)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(inReach ? Color.havenOnline : Color.gray)
                                    .frame(width: 7, height: 7)
                                Text(inReach ? MyDevicesStatus.sharingLine : "Not in reach")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        removing = device
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(device.displayName)")
                }
            }
            // The iPhone's twin is FipsMeshMyDevicesSection: Add a device is
            // the two-scan pairing (PairDeviceView), with Copy code and Paste
            // instead; a Linux box or browser relay page is pasted there by
            // its mesh address (Logen via Tod, 2026-11-08).
            Button {
                showPair = true
            } label: {
                Label("Add a device", systemImage: "plus.circle.fill")
                    .font(.appBody)
                    .foregroundColor(.havenPurple)
            }
            .buttonStyle(.plain)
        } header: {
            Text("My Devices")
        } footer: {
            Text(MyDevicesStatus.header)
        }
        // Remove asks first, as on the iPhone's device page.
        .confirmationDialog("Remove \(removing?.displayName ?? "device")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { device in
            Button("Remove", role: .destructive) { remove(device) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It can no longer reach this Mac over the mesh. Anything already on it stays there.")
        }
    }

    private func remove(_ device: MeshDevice) {
        configService.config.meshDevices = MeshDevicesLogic.removing(npub: device.npub, from: configService.config.meshDevices)
        configService.save()
        MeshCopyV2Service.shared.forget(peer: device.npub)
        mesh.sync()
    }

    // MARK: 4 Sync

    private var syncSection: some View {
        Section {
            Text("Your phones sync with this Mac. Check sync from Mesh on the phone.")
                .font(.appCaption)
                .foregroundColor(.secondary)
            // The iPhone's twin is in FipsMeshShareSection (was a "Photos go to" picker).
            Text(MeshPhotoPath.explainer)
                .font(.appCaption)
                .foregroundColor(.secondary)
        } header: {
            Text("Sync")
        }
    }

    // MARK: 5 Share With Others

    private var shareSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { configService.config.fipsPublishEnabled },
                set: { on in
                    configService.config.fipsPublishEnabled = on
                    configService.save()
                    NostrService.shared.publishServerList(fipsDetectedNpub: detection.detectedNpub)
                }
            )) {
                Text("List in my media servers")
                    .font(.appBody)
                    .settingInfo(.shareFIPS)
            }
            if let url = configService.config.fipsBlossomURL(detectedNpub: detection.detectedNpub) {
                HStack {
                    Text(url)
                        .font(.appSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.appSystem(size: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy address")
                }
            }
        } header: {
            Text("Share With Others")
        } footer: {
            Text("Lists this vault's .fips address in your media servers, so apps that speak the mesh (FIPS) can load your media without a public IP or domain. The mesh must be running for it to answer.")
        }
    }

    // MARK: 6 Advanced

    private var advancedSection: some View {
        Section {
            if let npub = mesh.ownNpub {
                HStack {
                    Text(npub)
                        .font(.appSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copied ? "Copied" : "Copy mesh address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(npub, forType: .string)
                        copied = true
                    }
                }
            }
            Picker("Address source", selection: Binding(
                get: { configService.config.fipsAddressSource },
                set: { value in
                    configService.config.fipsAddressSource = value
                    configService.save()
                    NostrService.shared.publishServerList(fipsDetectedNpub: detection.detectedNpub)
                }
            )) {
                Text("My Nostr npub").tag("owner")
                if detection.detectedNpub != nil {
                    Text("Detected (nostr-vpn)").tag("detected")
                }
                Text("Custom").tag("custom")
            }
            if configService.config.fipsAddressSource == "custom" {
                TextField("npub1...", text: Binding(
                    get: { configService.config.fipsCustomNpub },
                    set: { value in
                        configService.config.fipsCustomNpub = value
                        configService.save()
                    }
                ))
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .font(.appSystem(size: 12, design: .monospaced))
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("This Mac's mesh address, for a device that can't scan (a Linux box). Address source: which npub the listed .fips address uses.")
        }
    }
}
#endif

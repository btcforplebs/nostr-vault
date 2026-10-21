import SwiftUI

#if os(macOS)
/// FIPS Mesh on the Mac: the same sections, in the same order, as the iPhone
/// page. The Mac app runs no mesh engine itself (a FIPS transport such as
/// nostr-vpn does), so Mesh shows the transport, Sync points at the phones,
/// and Advanced holds the published address's source.
struct MacFipsMeshSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @StateObject private var detection = FIPSDetectionService()
    @State private var showQR = false
    @State private var newAddress = ""
    @State private var newName = ""
    @State private var newRole: MeshDeviceRole = .phone
    @State private var addError: String?

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
        .onAppear { detection.startPolling() }
        .onDisappear { detection.stopPolling() }
    }

    // MARK: 1 Mesh

    private var meshSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Mesh")
        } footer: {
            Text("Your devices reach each other over the FIPS mesh, with no public IP or domain. On a Mac the mesh runs in a FIPS transport such as nostr-vpn.")
        }
    }

    private var statusColor: Color {
        switch detection.status {
        case .running: return .havenOnline
        case .installed, .stale: return .yellow
        case .notInstalled: return .gray
        }
    }

    private var statusText: String {
        switch detection.status {
        case .running: return "On · FIPS transport active"
        case .stale: return "FIPS transport not responding"
        case .installed: return "Off · FIPS transport installed but not running"
        case .notInstalled: return "Off · no FIPS transport found"
        }
    }

    // MARK: 2 This Device

    private var thisDeviceSection: some View {
        Section {
            if let npub = detection.detectedNpub {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mesh address")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text(npub)
                        .font(.appSystem(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(npub, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        withAnimation(Motion.control) { showQR.toggle() }
                    } label: {
                        Label(showQR ? "Hide QR" : "Show QR", systemImage: "qrcode")
                    }
                }
                if showQR {
                    MeshQRCode.view(for: npub, label: "This Mac's mesh address QR code")
                }
            } else {
                Text("No mesh address yet. Start a FIPS transport such as nostr-vpn and it shows here.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("This Device")
        } footer: {
            Text("Add this address on your phones under FIPS Mesh → My Devices, as Vault on Mac.")
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
                    }
                    Spacer()
                    Button(role: .destructive) {
                        configService.config.meshDevices = MeshDevicesLogic.removing(npub: device.npub, from: configService.config.meshDevices)
                        configService.save()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(device.displayName)")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("npub1… mesh address", text: $newAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.appSystem(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                HStack {
                    Picker("This is", selection: $newRole) {
                        ForEach(MeshDeviceRole.allCases) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .frame(maxWidth: 220)
                    TextField("Name (optional)", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add a device by address", action: addDevice)
                        .disabled(HomeVaultLogic.meshNpub(fromInput: newAddress) == nil)
                }
                if let addError {
                    Text(addError)
                        .font(.appCaption)
                        .foregroundColor(.red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("My Devices")
        } footer: {
            Text("Your phones, home vault and browser page, in one list. Copy each one's address from FIPS Mesh → This Device on that device.")
        }
    }

    private func addDevice() {
        guard let npub = HomeVaultLogic.meshNpub(fromInput: newAddress) else {
            addError = "That isn't a mesh address."
            return
        }
        guard npub != detection.detectedNpub else {
            addError = "That is this Mac's own address."
            return
        }
        let device = MeshDevice(npub: npub, name: newName.trimmingCharacters(in: .whitespacesAndNewlines), role: newRole)
        configService.config.meshDevices = MeshDevicesLogic.adding(device, to: configService.config.meshDevices)
        configService.save()
        newAddress = ""
        newName = ""
        addError = nil
    }

    // MARK: 4 Sync

    private var syncSection: some View {
        Section {
            Text("Your phones sync with this Mac. Check sync from FIPS Mesh on the phone.")
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
            Text("Lists this Mac's .fips address in your Blossom server list, so apps with a FIPS transport can load your media without a public IP or domain. A FIPS transport must be running for it to answer.")
        }
    }

    // MARK: 6 Advanced

    private var advancedSection: some View {
        Section {
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
            Text("Which npub the listed .fips address uses.")
        }
    }
}
#endif

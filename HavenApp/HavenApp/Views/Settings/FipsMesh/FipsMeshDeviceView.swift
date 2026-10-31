import SwiftUI

#if os(iOS)
/// One of your devices: what it does for you, its address, its name, what is
/// on its way to it, and Remove.
struct FipsMeshDeviceView: View {
    let npub: String
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mesh = FipsMeshService.shared
    @State private var name = ""
    @State private var confirmRemove = false

    private var device: MeshDevice? {
        FipsMeshDevices.current(configService.config).first { $0.npub == npub }
    }

    var body: some View {
        List {
            if let device {
                content(device)
            }
        }
        .listStyle(.insetGrouped)
        .tint(Color.havenPurple)
        .navigationTitle(device?.displayName ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = device?.name ?? "" }
    }

    @ViewBuilder
    private func content(_ device: MeshDevice) -> some View {
        Section {
            FipsMeshDeviceRow(
                device: device,
                inReach: mesh.status?.running == true ? mesh.status?.peers?.contains(device.npub) == true : nil
            )
            Text(device.role.job)
                .font(.appCaption)
                .foregroundColor(.secondary)
            LabeledContent("Name") {
                TextField(device.role.label, text: $name)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { FipsMeshDevices.rename(device, to: name, config: configService) }
            }
        }

        Section {
            Text(device.npub)
                .font(.appSystem(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = device.npub
            } label: {
                Label("Copy address", systemImage: "doc.on.doc").font(.appBody)
            }
        } header: {
            Text("Mesh Address")
        }

        switch device.role {
        case .homeVault: HomeVaultSection()
        case .browser: BrowserRelaySection()
        case .mac, .phone: EmptyView()
        }

        Section {
            Button("Remove from My Devices", role: .destructive) { confirmRemove = true }
        } footer: {
            Text(removeFooter(device))
        }
        .confirmationDialog("Remove \(device.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                FipsMeshDevices.remove(device, config: configService)
                dismiss()
            }
        }
    }

    private func removeFooter(_ device: MeshDevice) -> String {
        switch device.role {
        case .mac: return "This phone stops syncing with your Mac over the mesh. Anything already on the Mac stays there."
        case .homeVault: return "New notes and media stop going to it, and it leaves your media server list. Anything already on it stays there."
        case .browser: return "Your notes stop going to the page. Anything already on it stays there."
        case .phone: return "It leaves your list. Anything already on it stays there."
        }
    }
}
#endif

import SwiftUI

#if os(iOS)
/// FIPS Mesh → This Device: the address other devices add to reach this
/// phone, its mesh IP while the engine runs, Copy and Show QR.
struct FipsMeshThisDeviceSection: View {
    @ObservedObject private var mesh = FipsMeshService.shared
    /// Read from the mesh key once, so the address shows before the first start.
    @State private var keyNpub: String?
    @State private var showQR = false

    private var address: String? { mesh.ownMeshNpub ?? keyNpub }

    var body: some View {
        Section {
            if let address {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mesh address")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text(address)
                        .font(.appSystem(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)

                if let ip = mesh.status?.address {
                    HStack {
                        Text("Mesh IP").font(.appBody)
                        Spacer()
                        Text(ip)
                            .font(.appSystem(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = address
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.appSystem(size: 12, weight: .bold))
                            .foregroundStyle(Color.havenPurple)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        withAnimation(Motion.control) { showQR.toggle() }
                    } label: {
                        Label(showQR ? "Hide QR" : "Show QR", systemImage: "qrcode")
                            .font(.appSystem(size: 12, weight: .bold))
                            .foregroundStyle(Color.havenPurple)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .tint(Color.havenPurple)

                if showQR {
                    MeshQRCode.view(for: address, label: "This phone's mesh address QR code")
                }
            } else {
                Text("This phone has no mesh address yet.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("This Device")
        } footer: {
            Text("Add this address on your other devices, such as your Mac's list, so they can reach this phone.")
        }
        .task {
            guard mesh.ownMeshNpub == nil, keyNpub == nil else { return }
            keyNpub = await Task.detached { FipsMeshService.meshNpubFromKey() }.value
        }
    }
}
#endif

import SwiftUI

#if os(iOS)
/// FIPS Mesh → This Device: this phone's mesh address, its mesh IP while the
/// engine runs, and Link a device, the two-scan pairing (PairDeviceView) that
/// adds your other phone, iPad or Mac (Logen 2026-11-05). The address is
/// copied under Advanced, for what can't scan (a Linux box).
struct FipsMeshThisDeviceSection: View {
    @ObservedObject private var mesh = FipsMeshService.shared
    /// Opens the page's pairing sheet, the one My Devices' Add a device opens.
    @Binding var showPair: Bool
    /// Read from the mesh key once, so the address shows before the first start.
    @State private var keyNpub: String?

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
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                if let ip = mesh.status?.address {
                    HStack {
                        Text("Mesh IP").font(.appBody)
                        Spacer()
                        Text(ip)
                            .font(.appSystem(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("This phone has no mesh address yet.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }

            Button {
                showPair = true
            } label: {
                Label("Link a device", systemImage: "qrcode.viewfinder")
                    .font(.appBody)
                    .foregroundStyle(Color.havenPurple)
            }
        } header: {
            Text("This Device")
        } footer: {
            Text("Link your other phone, iPad or Mac with two scans. For something that can't scan, copy this address under Advanced.")
        }
        .task {
            guard mesh.ownMeshNpub == nil, keyNpub == nil else { return }
            keyNpub = await Task.detached { FipsMeshService.meshNpubFromKey() }.value
        }
    }
}
#endif

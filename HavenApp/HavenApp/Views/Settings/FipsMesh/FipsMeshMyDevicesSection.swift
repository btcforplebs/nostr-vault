import SwiftUI

#if os(iOS)
/// FIPS Mesh → My Devices: one list of the owner's own devices, meant as the
/// same list both ways (Logen, 2026-10-21: who I reach is who may reach me).
/// The phone engine has no allowlist yet, so today it is the devices this
/// phone reaches; nothing here claims more. Tap one for its page; Add a
/// device by address is the one way in for every role.
struct FipsMeshMyDevicesSection: View {
    let devices: [MeshDevice]
    /// Owned by the page: the sheet hangs off the page's List. On this
    /// Section it went on every row, so with a device listed two sheets fought
    /// over one flag and Add a device closed as it opened (2026-10-21).
    @Binding var showAdd: Bool
    /// The two-scan pairing (PairDeviceView), the one way to add a device.
    @Binding var showPair: Bool
    @ObservedObject private var mesh = FipsMeshService.shared

    var body: some View {
        Section {
            ForEach(devices) { device in
                NavigationLink {
                    FipsMeshDeviceView(npub: device.npub)
                } label: {
                    FipsMeshDeviceRow(device: device, inReach: isInReach(device))
                }
            }
            Button {
                showPair = true
            } label: {
                Label("Add a device", systemImage: "plus.circle.fill")
                    .font(.appBody)
                    .foregroundColor(.havenPurple)
            }
            // Only for what can't do the two scans yet: a Linux/Pi home
            // vault box and the browser relay page show just their address.
            Button {
                showAdd = true
            } label: {
                Text("Add a Linux box or browser relay by address")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("My Devices")
        } footer: {
            Text(MyDevicesStatus.header)
        }
    }

    private func isInReach(_ device: MeshDevice) -> Bool? {
        guard mesh.status?.running == true else { return nil }
        return mesh.status?.peers?.contains(device.npub) == true
    }
}

/// One device in My Devices: role icon, name, role, and whether the running
/// engine is connected to it (nil: the engine is not running).
struct FipsMeshDeviceRow: View {
    let device: MeshDevice
    let inReach: Bool?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.teal)
                    .frame(width: 28, height: 28)
                Image(systemName: device.role.icon)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.appBody)
                Text(device.role.label)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                // Under the role: the sharing line is too long for the row's end.
                if let inReach {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(inReach ? Color.havenOnline : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(inReach ? MyDevicesStatus.sharingLine : "Not in reach")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
#endif

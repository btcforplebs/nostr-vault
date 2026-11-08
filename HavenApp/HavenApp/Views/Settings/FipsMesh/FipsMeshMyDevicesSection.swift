import SwiftUI

#if os(iOS)
/// FIPS Mesh → My Devices: one list of the owner's own devices, meant as the
/// same list both ways (Logen, 2026-10-21: who I reach is who may reach me).
/// The phone engine has no allowlist yet, so today it is the devices this
/// phone reaches; nothing here claims more. Tap one for its page; Add a
/// device (the two scans, or Paste instead) is the one way in for every role.
struct FipsMeshMyDevicesSection: View {
    let devices: [MeshDevice]
    /// Owned by the page: the sheet hangs off the page's List. On this
    /// Section it went on every row, so with a device listed two sheets fought
    /// over one flag and Add a device closed as it opened (2026-10-21).
    /// The two-scan pairing (PairDeviceView), the one way to add a device; a
    /// Linux box or browser relay page is pasted there by its address.
    @Binding var showPair: Bool
    @ObservedObject private var mesh = FipsMeshService.shared
    /// Each device's advert on the finder relays, as Your space reads it, so
    /// a device out of reach says when it last shared (MyDevicesStatus).
    @StateObject private var model = MyDevicesPanelModel()

    var body: some View {
        Section {
            ForEach(devices) { device in
                NavigationLink {
                    FipsMeshDeviceView(npub: device.npub)
                } label: {
                    FipsMeshDeviceRow(device: device, inReach: isInReach(device), status: status(device))
                }
            }
            Button {
                showPair = true
            } label: {
                Label("Add a device", systemImage: "plus.circle.fill")
                    .font(.appBody)
                    .foregroundColor(.havenPurple)
            }
        } header: {
            Text("My Devices")
        } footer: {
            Text(MyDevicesStatus.header)
        }
        .task(id: devices.map(\.npub).joined(separator: ",")) {
            while !Task.isCancelled {
                await model.refresh(devices)
                try? await Task.sleep(for: .seconds(MyDevicesPanelModel.refreshEvery))
            }
        }
    }

    private func status(_ device: MeshDevice) -> MyDevicesStatus.Status {
        MyDevicesStatus.status(adverts: model.adverts[device.npub] ?? [], now: Int(Date().timeIntervalSince1970),
                               connected: false, checked: model.checked)
    }

    private func isInReach(_ device: MeshDevice) -> Bool? {
        guard mesh.status?.running == true else { return nil }
        return mesh.status?.peers?.contains(device.npub) == true
    }
}

/// One device in My Devices: role icon, name, role, and whether the running
/// engine is connected to it (nil: the engine is not running), else what its
/// advert says ("Offline · last shared 3 d ago"), as on Android.
struct FipsMeshDeviceRow: View {
    let device: MeshDevice
    let inReach: Bool?
    var status = MyDevicesStatus.Status(state: .unchecked, lastSeen: nil)

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
                if let row = MyDevicesStatus.settingsRow(inReach: inReach, status: status) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(row.on ? Color.havenOnline : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(row.text)
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

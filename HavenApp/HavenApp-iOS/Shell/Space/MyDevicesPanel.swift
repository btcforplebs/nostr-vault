import SwiftUI

/// Your space › My devices: which of your own devices (Settings › Mesh ›
/// My Devices) are on the mesh now, and when each one last was. "Connected
/// now" comes from this iPad's running mesh engine; the rest from each
/// device's FIPS overlay advert on the finder relays (MyDevicesStatus).
/// Twin of the web's desktop/space/MyDevices.jsx. Reads only.
struct MyDevicesPanel: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var mesh = FipsMeshService.shared
    @StateObject private var model = MyDevicesPanelModel()

    private var devices: [MeshDevice] { model.devices(configService.config) }
    private var peers: Set<String> { mesh.status?.running == true ? Set(mesh.status?.peers ?? []) : [] }

    var body: some View {
        let devices = devices
        VStack(alignment: .leading, spacing: 10) {
            if devices.isEmpty {
                Text("No devices yet. Add your home vault, phones or browser vault in Settings › Mesh › My Devices.")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(MyDevicesStatus.header)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(devices) { device in row(device) }
                if model.checking && !model.checked {
                    Text("Checking the mesh…").font(.appSystem(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .task(id: devices.map(\.npub).joined(separator: ",")) {
            // On screen: look now, then every few minutes.
            while !Task.isCancelled {
                await model.refresh(self.devices)
                try? await Task.sleep(for: .seconds(MyDevicesPanelModel.refreshEvery))
            }
        }
    }

    private func status(_ device: MeshDevice) -> MyDevicesStatus.Status {
        MyDevicesStatus.status(adverts: model.adverts[device.npub] ?? [], now: Int(Date().timeIntervalSince1970),
                               connected: peers.contains(device.npub), checked: model.checked)
    }

    private func row(_ device: MeshDevice) -> some View {
        let s = status(device)
        return HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: device.role.icon)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                Circle()
                    .fill(Self.dot(s.state))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(MyDevicesStatus.line(s))
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    static func dot(_ state: MyDevicesStatus.State) -> Color {
        switch state {
        case .connected, .online: return .green
        case .offline: return .gray
        case .unknown, .unchecked: return Color.white.opacity(0.25)
        }
    }
}

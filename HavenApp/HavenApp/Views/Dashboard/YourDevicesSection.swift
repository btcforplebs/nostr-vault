import SwiftUI

/// Vault Dashboard › Your devices: your linked devices, a green dot for one
/// this device is connected to now, and Add a device (the two-scan pairing).
/// The Mac's row opens its sync page, as "Second copy on your Mac" did; the
/// other devices and the Mesh settings row open the Mesh settings screen
/// (Logen 2026-11-06; Android YourDevicesCard).
struct YourDevicesSection: View {
    @EnvironmentObject var configService: ConfigService
    @State private var showPairing = false
    #if os(iOS)
    @ObservedObject private var mesh = FipsMeshService.shared
    #else
    @ObservedObject private var mesh = MacFipsMeshService.shared
    #endif
    /// The Mac row's second line, from the dashboard (its last sync).
    let macDetail: String

    private var devices: [MeshDevice] {
        #if os(iOS)
        FipsMeshDevices.current(configService.config)
        #else
        configService.config.meshDevices
        #endif
    }

    var body: some View {
        DashboardSection(title: "Your devices") {
            ForEach(devices) { device in
                if device.role == .mac {
                    DashboardRowLink(icon: device.role.icon, title: device.displayName, detail: macDetail, state: dotState(device)) {
                        MacSyncSettingsPage().settingsPage("Desktop vault sync")
                    }
                } else {
                    DashboardRowLink(icon: device.role.icon, title: device.displayName, detail: line(device), state: dotState(device)) {
                        meshSettings
                    }
                }
                DashboardDivider()
            }
            SettingLink(icon: "point.3.filled.connected.trianglepath.dotted", title: "Mesh settings", value: nil) {
                meshSettings
            }
            DashboardDivider()
            DashboardRow(
                icon: "plus",
                title: "Add a device",
                detail: devices.isEmpty ? "Link your other phones, Mac or mobile vault. Two scans." : "Two scans: one shows a code, the other scans it.",
                state: .info
            ) {
                RowButton(title: "Add", isLoading: false) { showPairing = true }
            }
        }
        .sheet(isPresented: $showPairing) {
            PairDeviceView()
                .environmentObject(configService)
        }
    }

    /// The existing Mesh settings screen, as Settings › Mesh opens it.
    @ViewBuilder private var meshSettings: some View {
        #if os(iOS)
        FipsMeshSettingsView().settingsPage("Mesh")
        #else
        MacFipsMeshSettingsView().settingsPage("Mesh")
        #endif
    }

    /// Connected now (the running engine's peers). The Mac's engine reports no
    /// peers, so there the dot only says the device is linked.
    private func connected(_ device: MeshDevice) -> Bool? {
        #if os(iOS)
        guard mesh.status?.running == true else { return nil }
        return mesh.status?.peers?.contains(device.npub) == true
        #else
        return nil
        #endif
    }

    private func dotState(_ device: MeshDevice) -> RowState {
        connected(device) == true ? .done : .info
    }

    private func line(_ device: MeshDevice) -> String {
        switch connected(device) {
        case true?: return MyDevicesStatus.line(.init(state: .connected, lastSeen: nil))
        case false?: return "\(device.role.label) · not in reach now"
        case nil: return device.role.label
        }
    }
}

import SwiftUI

/// Mac only in the sidebar: two switches about when the relay comes up.
/// iPhone shows auto-start inline in the Settings list instead.
struct StartupSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                #if os(macOS)
                Toggle("Launch at Login", isOn: $configService.config.launchAtLogin)
                #endif
                Toggle(isOn: $configService.config.autoStartRelay) {
                    Text("Start Relay Automatically").settingInfo(.relayAutoStart)
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

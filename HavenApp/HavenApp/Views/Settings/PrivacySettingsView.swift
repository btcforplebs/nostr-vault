import SwiftUI

/// Lookups that send a request signed by your key to a third party, naming
/// whose profile or which article you are looking at. Each is off until
/// turned on here. Android: PrivacySettingsScreen.kt.
struct PrivacySettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $configService.config.vertexLookups) {
                    Text("Follower Counts from Vertex").settingInfo(.privacyVertex)
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Off, a profile's follower count comes from your relays, which may count fewer.")
            }

            Section {
                Toggle(isOn: $configService.config.fanfaresAutoCheck) {
                    Text("Check Fanfares Articles").settingInfo(.privacyFanfares)
                }
            } header: {
                Text("Articles")
            } footer: {
                Text("Off, a locked Fanfares article opens when you tap Already unlocked?")
            }
        }
    }
}

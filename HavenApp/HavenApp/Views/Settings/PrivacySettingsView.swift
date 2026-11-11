import SwiftUI

/// Lookups that send a request signed by your key to a third party, naming
/// whose profile or which article you are looking at. Each is off until
/// turned on here. Android: PrivacySettingsScreen.kt.
struct PrivacySettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @AppStorage(InAppBrowser.openLinksKey) private var openLinksInApp = true

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
                Toggle("Open Links in Nostr Vault", isOn: $openLinksInApp)
            } header: {
                Text("Links")
            } footer: {
                Text("On, web links open in Nostr Vault's own browser, which keeps nothing after you close it. Off, they open in your default browser. .fips sites always open in Nostr Vault, over the mesh, so their address never goes to the internet.")
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

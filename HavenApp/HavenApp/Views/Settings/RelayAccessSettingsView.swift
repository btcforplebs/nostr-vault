import SwiftUI

/// Who may write to your relay's inbox and chat. These used to be split
/// between "Performance & Limits" and "Global Web of Trust" in Advanced,
/// although both answer the same question. The old Rate Limits rows (events
/// and connections per minute) are gone: haven-go never read them, it uses
/// its own fixed limits (haven-go/limits.go).
struct RelayAccessSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                Stepper(value: $configService.config.chatRelayWotDepth, in: RelayAccessLimits.followDistance) {
                    HStack {
                        Text("Follow Distance").settingInfo(.relayWotDepth)
                        Spacer()
                        Text("\(configService.config.chatRelayWotDepth)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: $configService.config.chatRelayMinFollowers, in: 0...100) {
                    HStack {
                        Text("Minimum Followers").settingInfo(.relayMinFollowers)
                        Spacer()
                        Text("\(configService.config.chatRelayMinFollowers)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Picker(selection: $configService.config.wotRefreshInterval) {
                    Text("Every hour").tag("1h")
                    Text("Every 12 hours").tag("12h")
                    Text("Every day").tag("24h")
                    Text("Every week").tag("168h")
                } label: {
                    Text("Refresh Trust List").settingInfo(.relayWotRefresh)
                }
            } header: {
                Text("Web of Trust")
            }
        }
        .groupedFormStyleCompat()
        .onAppear {
            let depth = configService.config.chatRelayWotDepth
            let clamped = RelayAccessLimits.clampedFollowDistance(depth)
            if clamped != depth { configService.config.chatRelayWotDepth = clamped }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

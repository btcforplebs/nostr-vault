import SwiftUI

/// Who may write to your relay's inbox and chat, and how fast. These used
/// to be split between "Performance & Limits" and "Global Web of Trust" in
/// Advanced, although both answer the same question.
struct RelayAccessSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                Stepper(value: $configService.config.chatRelayWotDepth, in: 1...5) {
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

            Section {
                Stepper(value: $configService.config.outboxMaxEventsPerMinute, in: 10...1000, step: 10) {
                    HStack {
                        Text("Events").settingInfo(.relayRateLimits)
                        Spacer()
                        Text("\(configService.config.outboxMaxEventsPerMinute) / min")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: $configService.config.outboxMaxConnectionsPerMinute, in: 1...100) {
                    HStack {
                        Text("Connections")
                        Spacer()
                        Text("\(configService.config.outboxMaxConnectionsPerMinute) / min")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Rate Limits")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

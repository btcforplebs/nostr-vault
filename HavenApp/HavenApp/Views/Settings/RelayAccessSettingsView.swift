import SwiftUI

/// Who may write to your relay's inbox and chat. These used to be split
/// between "Performance & Limits" and "Global Web of Trust" in Advanced,
/// although both answer the same question. The old Rate Limits rows (events
/// and connections per minute) are gone: haven-go never read them, it uses
/// its own fixed limits (haven-go/limits.go).
///
/// Follow Distance and Minimum Followers belong to the account you are on:
/// each account has its own (HavenConfig+AccountReach), and switching account
/// shows that account's values.
struct RelayAccessSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    private var account: String { configService.config.reachAccountNpub }
    private var reach: AccountReach { configService.config.reach(for: account) }

    /// The open account's level; writing it changes that account alone.
    private var depth: Binding<Int> {
        Binding(get: { reach.depth }, set: { value in
            var next = reach
            next.depth = value
            configService.config.setReach(next, for: account)
        })
    }

    private var minFollowers: Binding<Int> {
        Binding(get: { reach.minFollowers }, set: { value in
            var next = reach
            next.minFollowers = value
            configService.config.setReach(next, for: account)
        })
    }

    /// Only said when there is more than one account to tell apart.
    private var perAccountNote: String? {
        configService.config.vaultWhitelistNpubs.isEmpty
            ? nil : "These two settings are for the account you are on. Each of your accounts has its own."
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: depth, in: RelayAccessLimits.followDistance) {
                    HStack {
                        Text("Follow Distance").settingInfo(.relayWotDepth)
                        Spacer()
                        Text(FollowDistanceWords.short(reach.depth))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: minFollowers, in: AccountReach.minFollowersRange) {
                    HStack {
                        Text("Minimum Followers").settingInfo(.relayMinFollowers)
                        Spacer()
                        Text("\(reach.minFollowers)")
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
            } footer: {
                if let perAccountNote { Text(perAccountNote) }
            }
        }
        .warmFormBackground()
        .groupedFormStyleCompat()
        .onAppear {
            // A level saved by an older build (up to 5) is stored as what the relay runs.
            let depth = configService.config.chatRelayWotDepth
            let clamped = RelayAccessLimits.clampedFollowDistance(depth)
            if clamped != depth { configService.config.chatRelayWotDepth = clamped }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

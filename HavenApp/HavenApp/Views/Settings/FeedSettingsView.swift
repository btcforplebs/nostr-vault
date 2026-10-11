import SwiftUI

/// What the feed shows (where it reads from is Settings > Relays). The three
/// switches are the same values as the feed's toolbar buttons, so flipping
/// one in either place flips both.
struct FeedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @AppStorage(PendingPostManager.ActionType.countdownKey)
    private var sendDelay: Double = PendingPostManager.ActionType.countdownDefault

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $configService.config.showReposts) {
                    Text("Show Reposts").settingInfo(.feedReposts)
                }
                Toggle(isOn: $configService.config.showReplies) {
                    Text("Show Replies").settingInfo(.feedReplies)
                }
                Toggle(isOn: $configService.config.autoLoadNewPosts) {
                    Text("Auto-Load New Posts").settingInfo(.feedAutoLoad)
                }
            } header: {
                Text("What You See")
            }

            Section {
                #if os(iOS)
                NavigationLink {
                    RelayMatrixView()
                        .navigationTitle("Relays")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Text("Feed Relays")
                }
                #else
                // The Mac's Settings is a sidebar; switch it to Relays.
                Button("Feed Relays…") {
                    NotificationCenter.default.post(name: .havenOpenFeedRelaySettings, object: nil)
                }
                #endif
            } footer: {
                Text("Your feed reads from the relays marked Read.")
            }

            Section {
                Picker(selection: $sendDelay) {
                    ForEach(PendingPostManager.ActionType.countdownChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(Int(seconds))s").tag(seconds)
                    }
                } label: {
                    Text("Send Delay").settingInfo(.postSendDelay)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Posting")
            } footer: {
                Text(sendDelay == 0
                     ? "Posts go out as soon as you tap. There's no undo."
                     : "Posts wait \(Int(sendDelay)) seconds before going out, so you can undo or edit them.")
            }

            Section {
                Button("Reload Feed") {
                    FeedService.shared.forceReload()
                    FeedService.shared.refresh()
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Clears the posts loaded on this device and loads your feed again from its relays. To check for new posts, pull down on the feed.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: configService.config.showReposts) { _, _ in
            FeedService.shared.recomputeFilteredNotes()
        }
        .onChange(of: configService.config.showReplies) { _, _ in
            FeedService.shared.recomputeFilteredNotes()
        }
    }
}

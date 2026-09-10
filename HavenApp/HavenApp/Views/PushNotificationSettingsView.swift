import SwiftUI

struct PushNotificationSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Push Notifications", isOn: $configService.config.enablePushNotifications)
                    .onChange(of: configService.config.enablePushNotifications) { _, enabled in
                        configService.save()
                        if enabled {
                            if let token = PushNotificationService.shared.deviceToken {
                                Task {
                                    await PushNotificationService.shared.registerAllAccountsWithRemoteServer(deviceToken: token)
                                }
                            } else {
                                PushNotificationService.shared.requestPermissionAndRegister()
                            }
                        } else {
                            Task {
                                await PushNotificationService.shared.unregisterFromRemoteServer()
                            }
                        }
                    }
            } footer: {
                Text("Receive notifications for mentions, replies, DMs, zaps, and more.")
            }

            if configService.config.enablePushNotifications {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    AccountNotificationSection(npub: npub)
                }
            }

            Section {} // spacer for tab bar
        }
        .padding(.bottom, 60)
    }
}

struct AccountNotificationSection: View {
    let npub: String
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared

    private var prefs: Binding<NotificationPreferences> {
        Binding(
            get: {
                configService.config.notificationPrefsPerAccount[npub] ?? NotificationPreferences()
            },
            set: { newValue in
                PushNotificationService.shared.updatePreferences(newValue, forAccount: npub)
            }
        )
    }

    private var displayName: String {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        return profile?.bestName ?? String(npub.prefix(12)) + "..."
    }

    private var isOwner: Bool {
        npub == configService.config.ownerNpub
    }

    var body: some View {
        Section {
            Toggle("Mentions", isOn: prefs.mentions)
            Toggle("Replies", isOn: prefs.replies)
            Toggle("Direct Messages", isOn: prefs.dms)
            Toggle("Zaps", isOn: prefs.zaps)
            if !configService.config.zapsOnlyMode {
                Toggle("Reactions", isOn: prefs.reactions)
            }
            Toggle("Reposts", isOn: prefs.reposts)
        } header: {
            HStack(spacing: 8) {
                let hex = Bech32.decode(npub)?.hexString ?? ""
                let profile = nostrService.profiles[hex]
                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 20)
                Text(displayName)
                if isOwner {
                    Text("Owner")
                        .font(.appCaption2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

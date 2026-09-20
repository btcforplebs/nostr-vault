import AVFoundation
import SwiftUI

struct PushNotificationSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: $configService.config.enablePushNotifications)
                    .onChange(of: configService.config.enablePushNotifications) { _, enabled in
                        configService.save()
                        if enabled {
                            PushNotificationService.shared.requestPermissionAndRegister()
                        }
                    }
            } footer: {
                Text("Notifications for mentions, replies, DMs, zaps, and more are generated on-device by your relay — no external server involved.")
            }

            if configService.config.enablePushNotifications {
                Section {
                    Toggle("New notes in your feed", isOn: $configService.config.enableFeedNotifications)
                        .onChange(of: configService.config.enableFeedNotifications) { _, _ in
                            configService.save()
                        }
                } footer: {
                    Text("A single summary of what people you follow posted, and only after you have been away for a couple of hours. Everything else here is about notes addressed to you.")
                }

                NotificationSoundSection()

                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    AccountNotificationSection(npub: npub)
                }
            }

            Section {} // spacer for tab bar
        }
        .padding(.bottom, 60)
    }
}

struct NotificationSoundSection: View {
    @EnvironmentObject var configService: ConfigService
    @State private var previewPlayer: AVAudioPlayer?

    private var selectedSound: NotificationSound {
        NotificationSound(rawValue: configService.config.notificationSoundName) ?? .defaultSound
    }

    var body: some View {
        Section {
            Picker("Sound", selection: Binding(
                get: { selectedSound },
                set: { newSound in
                    configService.config.notificationSoundName = newSound.rawValue
                    configService.save()
                    preview(newSound)
                }
            )) {
                ForEach(NotificationSound.allCases) { sound in
                    Text(sound.displayName).tag(sound)
                }
            }
        } header: {
            Text("Sound")
        }
    }

    private func preview(_ sound: NotificationSound) {
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "mp3") else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            previewPlayer = player // retain until playback finishes
            player.play()
        } catch {
            // Best-effort preview — a failed play shouldn't block picking the sound.
        }
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

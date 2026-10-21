import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var showEmojiPicker = false

    private var deviceLanguageName: String {
        let code = NoteTranslation.targetCode(setting: "")
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current) ?? code
    }

    var body: some View {
        Form {
            // Accent Theme picker removed — the app ships a single appearance
            // (OLED black with the orange accent), so there is nothing to choose.

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text Size").settingInfo(.displayTextSize)
                        Spacer()
                        Text(String(format: "%.0f%%", configService.config.textSizeScale * 100))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(
                        value: $configService.config.textSizeScale,
                        in: 0.8...1.6,
                        step: 0.1
                    ) {
                        Text("Text Size")
                    } minimumValueLabel: {
                        Text("A").font(.appSystem(size: 12))
                    } maximumValueLabel: {
                        Text("A").font(.appSystem(size: 20))
                    }
                    .onChange(of: configService.config.textSizeScale) { _, _ in
                        configService.save()
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Text")
            }

            // OLED black is the app's only appearance now, so there is nothing
            // left to toggle here — the section was removed along with the
            // colour-theme picker below.

            Section {
                lineLimitStepper("Compact View", systemImage: "rectangle.compress.vertical",
                                 value: $configService.config.compactLineLimit, info: .displayCompactLines)
                lineLimitStepper("Threaded View", systemImage: "list.bullet.indent",
                                 value: $configService.config.threadedLineLimit, info: .displayThreadedLines)
            } header: {
                Text("Feed Text")
            } footer: {
                Text("Lines of text each post shows before it is cut off. In Threaded View, replies show one line fewer.")
            }

            #if os(iOS)
            Section {
                Toggle(isOn: $configService.config.disableTabBarAnimation) {
                    Label {
                        Text("Keep Tab Bar Full Size").settingInfo(.displayTabBarAnimation)
                    } icon: {
                        Image(systemName: "rectangle.bottombar.fill")
                    }
                }
                .onChange(of: configService.config.disableTabBarAnimation) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Tab Bar")
            }
            #endif

            Section {
                Toggle(isOn: $configService.config.showTranslateButton) {
                    Label("Translate Button on Posts", systemImage: "translate")
                }
                .onChange(of: configService.config.showTranslateButton) { _, _ in
                    configService.save()
                }
                Picker(selection: $configService.config.translateTargetLanguage) {
                    Text("Device Language (\(deviceLanguageName))").tag("")
                    ForEach(FeedLanguage.pickerList) { language in
                        Text(language.displayName).tag(language.code)
                    }
                } label: {
                    Label("Translate To", systemImage: "globe")
                }
                .disabled(!configService.config.showTranslateButton)
                .onChange(of: configService.config.translateTargetLanguage) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Translation")
            } footer: {
                Text("Posts in other languages get a Translate button. Translation runs on this device with Apple's translator, and nothing is sent anywhere. The first time, your device downloads the language.")
            }

            Section {
                Toggle(isOn: $configService.config.showNewPostsPill) {
                    Label {
                        Text("New Posts Pill").settingInfo(.displayNewPostsPill)
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                }
                .onChange(of: configService.config.showNewPostsPill) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Feed")
            } footer: {
                Text("Off, new posts wait until you pull down to refresh.")
            }

            PostButtonsSection()

            Section {
                Toggle(isOn: $configService.config.zapsOnlyMode) {
                    Label {
                        Text("Zaps Only").settingInfo(.displayZapsOnly)
                    } icon: {
                        Image(systemName: "bolt.fill")
                    }
                }
                .onChange(of: configService.config.zapsOnlyMode) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Engagement")
            }

            if !configService.config.zapsOnlyMode {
                Section {
                    // A tap gesture rather than a Button: the (i) is a button
                    // too, and a Button inside a Button's label never fires.
                    HStack {
                        Label("Default Reaction", systemImage: "heart.fill")
                            .foregroundColor(.primary)
                        InfoButton(.displayDefaultReaction)
                        Spacer()
                        Text(configService.config.defaultReactionEmoji)
                            .font(.appSystem(size: 24))
                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showEmojiPicker = true }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isButton)
                } header: {
                    Text("Reactions")
                }
            }
        }
        .groupedFormStyleCompat()
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerView { emoji in
                configService.config.defaultReactionEmoji = emoji
                configService.save()
                showEmojiPicker = false
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// One feed layout's line count, saved as it changes.
    private func lineLimitStepper(_ title: LocalizedStringKey, systemImage: String,
                                  value: Binding<Int>, info: SettingsHelp) -> some View {
        Stepper(value: value, in: HavenConfig.lineLimitRange) {
            Label {
                HStack {
                    Text(title).settingInfo(info)
                    Spacer()
                    Text(value.wrappedValue == 1 ? "1 line" : "\(value.wrappedValue) lines")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .onChange(of: value.wrappedValue) { _, _ in configService.save() }
    }


    
}

/// Settings → Post buttons: the emoji the action bar under a post shows. Adding
/// ⚡️ turns on the zap button on posts, which ships off on iOS and the Mac. Labeled and in
/// plain sight on purpose — App Review has to be able to find it.
private struct PostButtonsSection: View {
    @AppStorage(PostButtons.storageKey) private var postButtons = ""

    var body: some View {
        Section {
            HStack {
                Label {
                    Text("Post buttons")
                } icon: {
                    Image(systemName: "hand.tap")
                }
                Spacer()
                TextField("Add ⚡️", text: $postButtons)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .frame(maxWidth: 140)
            }
            preview
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PostButtons.showsZap(postButtons)
                    ? "Preview: reply, repost, quote, react, zap"
                    : "Preview: reply, repost, quote, react")
        } header: {
            Text("Post buttons")
        } footer: {
            Text("Add ⚡️ to show a zap button on posts, live streams and locked articles. Zaps go straight from your own wallet to the author over Nostr Wallet Connect. Profile zaps are always available.")
        }
    }

    private var preview: some View {
        HStack(spacing: 8) {
            ForEach(previewIcons, id: \.self) { icon in
                Image(systemName: icon)
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(icon == "bolt" ? .orange : .secondary)
                    .frame(width: 32, height: 32)
                    .background(icon == "bolt" ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
        .animation(Motion.pop, value: PostButtons.showsZap(postButtons))
    }

    private var previewIcons: [String] {
        let base = ["message", "arrow.2.squarepath", "quote.closing", "heart"]
        return PostButtons.showsZap(postButtons) ? base + ["bolt"] : base
    }
}

import SwiftUI

/// Settings › Blocked › Muted words: the words in the active account's kind
/// 10000, which hide notes that use them. New words go in the encrypted part
/// unless Public is on. Embedded in `BlockedSettingsView`'s form as its own
/// sections. Android: MutedWordsScreen.kt; web: screens/settings/MutedWords.jsx.
struct MutedWordsSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    @State private var typed = ""
    /// Add as a public entry. Off by default: a public list says what upsets you.
    @State private var addPublicly = false
    /// Words with a publish under way, so their row can't be tapped twice.
    @State private var busy: Set<String> = []
    @State private var adding = false
    /// Bumped when the mute list is reopened, which the config doesn't publish.
    @State private var revision = 0

    private var list: MuteList {
        _ = revision
        let npub = configService.mutedWordsAccountNpub
        guard let hex = Bech32.decode(npub)?.hexString else { return .empty }
        return MuteListStore.shared.list(forHex: hex)
    }

    /// The private part couldn't be opened: private words are unknown, and
    /// adding one would lose them.
    private var privateLocked: Bool { !list.privateNote.isEmpty }

    private var candidate: String? { MutedWordsEdit.normalized(typed) }

    private var canAdd: Bool {
        guard let word = candidate, !adding else { return false }
        if !addPublicly && privateLocked { return false }
        return !list.words.contains(word)
    }

    var body: some View {
        Section {
            HStack {
                TextField("Word or phrase", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(add)
                    .accessibilityLabel("Word or phrase to mute")
                Button(adding ? "Muting…" : "Mute", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
            Toggle("Public", isOn: $addPublicly)
        } header: {
            Text("Muted Words")
        } footer: {
            Text(footer)
        }

        Section {
            let words = list.words.sorted()
            if words.isEmpty {
                Text("No muted words.").foregroundColor(.secondary)
            } else {
                ForEach(words, id: \.self) { word in
                    row(word)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))) { _ in
            revision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: MuteListStore.settled)) { _ in
            revision += 1
        }
    }

    private var footer: String {
        if !addPublicly && privateLocked {
            return "Your private muted words can't be opened, so none can be added. Is your signer connected? (\(list.privateNote))"
        }
        return addPublicly
            ? "Anyone can see this word in your mute list."
            : "Only you will see this word. It is encrypted in your mute list and shows once your relays have it."
    }

    private func row(_ word: String) -> some View {
        let isPublic = list.publicWords.contains(word) || !list.privateWords.contains(word)
        let working = busy.contains(word)
        return HStack(spacing: 10) {
            Text(word)
                .lineLimit(2)
            Text(isPublic ? "Public" : "Private")
                .font(.appCaption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
            if working {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button(isPublic ? "Make private" : "Make public") {
                        publish(word) { configService.setMutedWord(word, publicly: !isPublic, done: $0) }
                    }
                    .disabled(isPublic && privateLocked)
                    Button("Remove", role: .destructive) {
                        publish(word) { configService.unmuteWord(word, done: $0) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Options for \(word)")
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }

    private func add() {
        guard canAdd, let word = candidate else { return }
        adding = true
        configService.muteWord(word, publicly: addPublicly) { saved in
            adding = false
            if saved { typed = "" }
        }
    }

    private func publish(_ word: String, _ run: (@escaping @MainActor (Bool) -> Void) -> Void) {
        busy.insert(word)
        run { _ in busy.remove(word) }
    }
}

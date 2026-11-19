import SwiftUI

/// New message: find the person, then their chat opens, with its history,
/// photos and video (B2, 2026-11-19). One picker for iPhone, iPad and Mac
/// in place of two text-only composers; the rules are DMRecipientQuery.
struct DMNewChatPicker: View {
    let onPick: (String) -> Void

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var outcome: DMRecipientQuery.Outcome {
        DMRecipientQuery.resolve(typed, names: nostrService.profiles.compactMapValues { $0.bestName },
                                 blocked: configService.activeAccountBlockedHexPubkeys,
                                 own: configService.activeAccountHexPubkey)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Name, npub or nprofile", text: $typed)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focused)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(16)
                    .onSubmit { if case .key(let hex) = outcome { onPick(hex) } }
                results
                Spacer(minLength: 0)
            }
            .navigationTitle(String(localized: "dm.compose.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "dm.compose.cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .onAppear { focused = true }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch outcome {
        case .idle:
            hint("Type a name you follow, or paste their npub to message someone new.")
        case .key(let hex):
            row(hex).onAppear { nostrService.fetchMissingProfiles(for: [hex]) }
        case .matches(let hexes):
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(hexes, id: \.self) { row($0) } }
            }
        case .blocked:
            hint("You blocked this person. Unblock them on their profile to message them.")
        case .badKey:
            hint("That key isn't valid. Check it and paste it again.")
        case .yourself:
            hint("That's your own account.")
        case .noMatch:
            hint("No one loaded matches “\(typed.trimmingCharacters(in: .whitespaces))”. Paste their npub to message someone new.")
        }
    }

    private func row(_ hex: String) -> some View {
        let profile = nostrService.profiles[hex]
        return Button { onPick(hex) } label: {
            HStack(spacing: 10) {
                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 32)
                Text(profile?.bestName ?? String(hex.prefix(8)) + "…")
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.appSystem(size: 13))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 8)
    }
}

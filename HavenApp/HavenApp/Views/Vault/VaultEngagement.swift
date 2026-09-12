import SwiftUI

// MARK: - Reaction Emoji Display

/// Maps raw kind-7 reaction content to a displayable emoji.
/// "+"/empty is a standard like (heart), "-" a dislike; custom-emoji
/// shortcodes and plain text fall back to the heart.
func reactionDisplayEmoji(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed {
    case "", "+", "+1", "❤", "❤️": return "❤️"
    case "-", "-1": return "👎"
    default: break
    }
    if let emoji = trimmed.first(where: { $0.isEmojiRenderable }) {
        return String(emoji)
    }
    return "❤️"
}

/// Unique display emojis for a set of raw reaction contents, in first-seen order.
func reactionEmojiSummary(_ emojis: [String], limit: Int) -> String {
    var seen = Set<String>()
    var result: [String] = []
    for raw in emojis {
        let display = reactionDisplayEmoji(raw)
        if seen.insert(display).inserted {
            result.append(display)
            if result.count == limit { break }
        }
    }
    return result.isEmpty ? "❤️" : result.joined()
}

private extension Character {
    /// True when the character renders as an emoji glyph (excludes plain digits/text).
    var isEmojiRenderable: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || unicodeScalars.contains { $0.properties.isEmojiModifierBase }
            || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}


// MARK: - ReactorsListView

struct ReactorsListView: View {
    let reactors: [(pubkey: String, emoji: String)]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(Array(reactors.enumerated()), id: \.offset) { _, reactor in
                let profile = nostrService.profiles[reactor.pubkey]
                Button {
                    selectedProfilePubkey = reactor.pubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: reactor.pubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.bestName ?? "npub…" + String(reactor.pubkey.suffix(6)))
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile?.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(Color.havenPurple)
                            }
                        }

                        Spacer()

                        Text(reactionDisplayEmoji(reactor.emoji))
                            .font(.appSystem(size: 20))

                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Reactions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}

// MARK: - RepostersListView

struct RepostersListView: View {
    let pubkeys: [String]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(pubkeys, id: \.self) { pubkey in
                let profile = nostrService.profiles[pubkey]
                Button {
                    selectedProfilePubkey = pubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.bestName ?? "npub\u{2026}" + String(pubkey.suffix(6)))
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile?.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(Color.havenPurple)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Reposted By")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}

// MARK: - QuotersListView

struct QuotersListView: View {
    let pubkeys: [String]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(pubkeys, id: \.self) { pubkey in
                let profile = nostrService.profiles[pubkey]
                Button {
                    selectedProfilePubkey = pubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.bestName ?? "npub\u{2026}" + String(pubkey.suffix(6)))
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile?.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(Color.havenPurple)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Quoted By")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}

import SwiftUI

/// Setup's people list opens this for one person (Logen 2026-11-22: each
/// row taps through to a profile preview with Follow, so people choose
/// instead of ticking strangers). Their profile, how they're tied to the
/// person who told you, and their last few notes, read from public relays.
/// Follow only marks them for setup to follow once the key is stored
/// (`SetupReferral.pendingFollows`); nothing is published here.
struct ReferralProfilePreview: View {
    let pubkey: String
    let relationLine: String
    let isFollowing: Bool
    /// true: follow them; false: don't.
    let onChoose: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var nostr = NostrService.shared
    @State private var notes: [NostrEvent] = []
    @State private var loadingNotes = true

    /// How many recent notes are shown.
    static let noteCount = 3

    var body: some View {
        ZStack {
            WizardColors.bgPrimary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    recentNotes
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { buttons }
        }
        .task { await loadNotes() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 84)
            Text(name)
                .font(.appSystem(size: 22, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if let nip05 = profile?.nip05, !nip05.isEmpty {
                Text(nip05.hasPrefix("_@") ? String(nip05.dropFirst(2)) : nip05)
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
                    .lineLimit(1)
            }
            Text(relationLine)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(WizardColors.accentPrimary)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(Capsule().fill(WizardColors.accentPrimary.opacity(0.12)))
            if let about = profile?.about, !about.isEmpty {
                Text(about)
                    .font(.appSystem(size: 14))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var recentNotes: some View {
        if loadingNotes {
            ProgressView().padding(.vertical, 16)
                .accessibilityLabel("Loading their notes")
        } else if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent notes")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(WizardColors.textMuted)
                ForEach(notes, id: \.id) { note in
                    Text(note.content)
                        .font(.appSystem(size: 14))
                        .foregroundColor(WizardColors.textPrimary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(WizardColors.bgCard)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
                }
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            WizardPrimaryButton(title: isFollowing ? "Don't follow" : "Follow \(name)") {
                onChoose(!isFollowing)
                dismiss()
            }
            WizardSkipLink(title: "Back to the list") { dismiss() }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(WizardColors.bgPrimary.opacity(0.95))
    }

    private var profile: FeedProfile? { nostr.profiles[pubkey] }

    private var name: String {
        profile?.bestName ?? ProfileFormat.shortPubkey(pubkey)
    }

    /// Their last few top-level notes (not replies), newest first.
    private func loadNotes() async {
        let events = await nostr.fetchEvents(
            filter: ["kinds": [1], "authors": [pubkey], "limit": 20], from: ReferralLookup.relays)
        notes = Array(events
            .filter { $0.pubkey == pubkey && !$0.tags.contains { $0.first == "e" } }
            .sorted { $0.created_at > $1.created_at }
            .prefix(Self.noteCount))
        loadingNotes = false
    }
}

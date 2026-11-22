import SwiftUI

/// "Why?" on a person's trust card: opens `TrustWhySheet`. Shown only when
/// your Haven's copy has a score for them; nothing otherwise. Android twin:
/// `TrustWhyButton` in `ui/components/trustweb/TrustWhySheet.kt`.
struct TrustWhyButton: View {
    let pubkey: String
    @ObservedObject private var config = ConfigService.shared
    @StateObject private var rank = TrustRankCopyWatch()
    @State private var open = false

    private var me: String { config.activeAccountHexPubkey }
    private var copy: TrustRankCopy? { rank.copy }

    /// Draws nothing without a score; `rank` loads from when the view is made.
    var body: some View {
        if copy?[pubkey] != nil, pubkey.caseInsensitiveCompare(me) != .orderedSame {
            Button { open = true } label: {
                Text("Why?")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.accentText)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows their score and who you follow follows them"))
            .sheet(isPresented: $open) {
                TrustWhySheet(pubkey: pubkey, me: me, copy: copy)
            }
        }
    }
}

/// Score, ring and the people you follow who follow them, highest score
/// first. No mute rows (Logen's question 3 is open). Android twin:
/// `ui/components/trustweb/TrustWhySheet.kt`.
struct TrustWhySheet: View {
    let pubkey: String
    let me: String
    let copy: TrustRankCopy?
    @EnvironmentObject var nostrService: NostrService
    @StateObject private var trust = LiveTrustPath()

    private var why: TrustWhy? { TrustWhy.of(pubkey: pubkey, me: me, copy: copy, path: trust.path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Why \(name(pubkey))?")
                    .font(.appSystem(size: 18, weight: .bold))
                    .lineLimit(1)
                if let why {
                    details(why)
                } else {
                    // The path can place them outside your web after all (an unfollow since the Haven ranked).
                    Text(trust.path == nil ? "Checking…" : "Your Haven's score for them is out of date.")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: pubkey) {
            trust.track(pubkey)
            nostrService.fetchMissingProfiles(for: [pubkey])
        }
        .onChange(of: why?.followers) { _, followers in
            nostrService.fetchMissingProfiles(for: [pubkey] + (followers ?? []).prefix(TrustWhy.shown).map(\.pubkey))
        }
    }

    @ViewBuilder
    private func details(_ why: TrustWhy) -> some View {
        Text(TrustWhyText.headline(why))
            .font(.appSystem(size: 28, weight: .bold))
            .foregroundColor(.accentText)
        Text(TrustWhyText.place(why)).font(.appSystem(size: 14))
        if let title = TrustWhyText.followersTitle(why) {
            Text(title)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 6)
        }
        ForEach(why.followers.prefix(TrustWhy.shown), id: \.pubkey) { follower in
            HStack(spacing: 10) {
                AvatarView(url: nostrService.profiles[follower.pubkey]?.pictureURL, pubkey: follower.pubkey, size: 28)
                Text(name(follower.pubkey))
                    .font(.appSystem(size: 14))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(follower.score.map(String.init) ?? "–")
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        if let more = TrustWhyText.more(why) {
            Text(more).font(.appSystem(size: 13)).foregroundColor(.secondary)
        }
        Text(TrustWhyText.how)
            .font(.appSystem(size: 12))
            .foregroundColor(.secondary.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        Text("Ranked by your Haven \(Self.ago(why.rankedAt))")
            .font(.appSystem(size: 12))
            .foregroundColor(.secondary.opacity(0.75))
    }

    /// "2h ago": the same words as Android's `RelativeTime.abbreviated`.
    private static func ago(_ seconds: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(seconds)), relativeTo: Date())
    }

    private func name(_ pk: String) -> String {
        nostrService.profiles[pk]?.bestName ?? "npub…\(pk.suffix(6))"
    }
}

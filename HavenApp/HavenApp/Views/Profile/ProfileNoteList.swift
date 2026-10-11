import SwiftUI

/// The rows under a profile's Notes, Replies, Reposts and Tagged tabs.
struct ProfileNoteList<Footer: View>: View {
    let notes: [FeedNote]
    let section: ProfileSection
    /// Whose profile this is.
    let pubkey: String
    let profile: FeedProfile?
    let feedService: FeedService
    let nostrService: NostrService
    let onReply: (FeedNote) -> Void
    let onQuote: (FeedNote) -> Void
    let onProfile: (String) -> Void
    let onMedia: (URL, [URL]) -> Void
    let onOpen: (FeedNote) -> Void
    @ViewBuilder let footer: () -> Footer

    private var engagementStore: ProfileEngagementStore { .shared }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                if idx > 0 {
                    Rectangle()
                        .fill(Color.platformSeparator.opacity(0.4))
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                }
                row(note)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(note) }
            }

            footer()
        }
        // Numbers under each post, fetched as the posts appear. The tagged
        // tab is other people's posts, so it is left out.
        .task(id: section == .tagged ? [] : notes.map(\.id)) {
            guard section != .tagged else { return }
            await engagementStore.load(ids: notes.map { feedService.originalNote(for: $0).id }, author: pubkey)
        }
        .scrollTargetLayout()
        .padding(.top, 4)
    }

    private func row(_ note: FeedNote) -> some View {
        FeedNoteRow(
            note: note,
            profile: section == .tagged ? nostrService.profiles[note.pubkey] : profile,
            rowData: FeedNoteRowData.resolve(
                for: note,
                feedService: feedService,
                nostrService: nostrService
            ).with(engagement: engagementStore.engagement(for: feedService.originalNote(for: note).id)),
            onReply: { onReply(note) },
            onQuote: { onQuote(note) },
            onProfile: onProfile,
            onMedia: onMedia,
            showParent: false
        )
    }
}

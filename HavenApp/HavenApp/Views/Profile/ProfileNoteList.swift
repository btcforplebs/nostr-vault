import SwiftUI

/// The rows under a profile's Notes, Replies, Reposts and Tagged tabs.
///
/// Observes nothing. Each row is a `ProfileNoteRowHost`, which redraws on
/// its own for the likes, numbers and profiles it shows, so this list's
/// body (and the page around it) runs only when the tab's notes change.
struct ProfileNoteList<Footer: View>: View {
    let notes: [FeedNote]
    let section: ProfileSection
    /// Whose profile this is.
    let pubkey: String
    let profile: FeedProfile?
    /// The loader's hash of this tab's note ids, worked out once per change
    /// to the notes (`ProfileFeedLoader.idsHash(for:)`).
    let idsHash: Int
    let feedService: FeedService
    let onReply: (FeedNote) -> Void
    let onQuote: (FeedNote) -> Void
    let onProfile: (String) -> Void
    let onMedia: (URL, [URL]) -> Void
    let onOpen: (FeedNote) -> Void
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        let firstID = notes.first?.id
        LazyVStack(spacing: 0) {
            ForEach(notes) { note in
                if note.id != firstID {
                    Rectangle()
                        .fill(Color.platformSeparator.opacity(0.4))
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                }
                ProfileNoteRowHost(note: note, section: section, profile: profile,
                                   onReply: onReply, onQuote: onQuote, onProfile: onProfile, onMedia: onMedia)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(note) }
            }

            footer()
        }
        // Numbers under each post, fetched as the posts appear. The tagged
        // tab is other people's posts, so it is left out. Keyed on a hash of
        // the ids, so a redraw does not copy the list to compare it.
        .task(id: section == .tagged ? 0 : idsHash) {
            guard section != .tagged else { return }
            await ProfileEngagementStore.shared.load(ids: notes.map { feedService.originalNote(for: $0).id }, author: pubkey)
        }
        .scrollTargetLayout()
        .padding(.top, 4)
    }
}

import SwiftUI

/// The rows under a profile's Notes, Replies, Reposts and Tagged tabs.
///
/// Its own view so the likes, reposts and zap counts under each post redraw
/// only the list. `ProfileEngagementStore` publishes as each relay answers,
/// and while it was observed by the whole page every answer rebuilt the
/// banner, header and tab bar too.
///
/// The page redraws only for its own person's profile, so the list watches
/// the people its rows show (tagged authors, reposted and replied-to people)
/// and redraws itself when one of theirs arrives.
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

    @ObservedObject private var engagementStore = ProfileEngagementStore.shared
    /// Bumped when a profile one of the rows shows arrives.
    @State private var profilesSeen = 0

    var body: some View {
        let _ = profilesSeen
        let firstID = notes.first?.id
        LazyVStack(spacing: 0) {
            ForEach(notes) { note in
                if note.id != firstID {
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
        // tab is other people's posts, so it is left out. Keyed on a hash of
        // the ids, so a redraw does not copy the list to compare it.
        .task(id: section == .tagged ? 0 : idsHash) {
            guard section != .tagged else { return }
            await engagementStore.load(ids: notes.map { feedService.originalNote(for: $0).id }, author: pubkey)
        }
        .onReceive(nostrService.$profileUpdates.dropFirst()) { signal in
            if !signal.pubkeys.isDisjoint(with: rowPeople) { profilesSeen &+= 1 }
        }
        .scrollTargetLayout()
        .padding(.top, 4)
    }

    private var idsHash: Int {
        var hasher = Hasher()
        for note in notes { hasher.combine(note.id) }
        return hasher.finalize()
    }

    /// Everyone whose name or picture a row draws.
    private var rowPeople: Set<String> {
        var people = Set<String>()
        for note in notes {
            people.insert(note.pubkey)
            if let reposter = note.repostedBy { people.insert(reposter) }
            if let repliedTo = note.replyToPubkey { people.insert(repliedTo) }
            people.insert(feedService.originalNote(for: note).pubkey)
            if let parent = note.parentEventId.flatMap({ feedService.findNote(id: $0) }) {
                people.insert(parent.pubkey)
            }
        }
        return people
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

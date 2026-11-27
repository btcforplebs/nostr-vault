import SwiftUI
import Combine

/// One row under a profile's Notes, Replies, Reposts and Tagged tabs, and
/// the only part of the page that redraws for what a row shows: your likes,
/// reactions, reposts and zaps, fetched parent and reposted notes, the
/// numbers under the post and the people it names.
///
/// Profile perf review 11-27 #5: the whole page observed all of that and
/// re-ran its body (the tab split, a hash over every note, every row's
/// `FeedNoteRowData.resolve`) about 10 times per swipe. Now a change
/// re-resolves only the rows on screen, and each row's view is skipped
/// when what it draws did not change (`ProfileNoteRowView`, Equatable).
struct ProfileNoteRowHost: View {
    let note: FeedNote
    let section: ProfileSection
    /// The page's own profile, for rows that are this person's notes.
    let profile: FeedProfile?
    let onReply: (FeedNote) -> Void
    let onQuote: (FeedNote) -> Void
    let onProfile: (String) -> Void
    let onMedia: (URL, [URL]) -> Void

    @ObservedObject private var signals = ProfileRowSignals.shared
    /// Bumped when a profile this row shows arrives.
    @State private var profilesSeen = 0

    private var feedService: FeedService { .shared }
    private var nostrService: NostrService { .shared }

    var body: some View {
        let _ = profilesSeen
        let original = feedService.originalNote(for: note)
        // Counts under each post are from people inside your web only.
        let isInside = GateInsideKeys.shared.predicate(for: feedService.feedGate)
        let data = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
            .with(engagement: ProfileEngagementStore.shared.engagement(for: original.id, isInside: isInside))
        ProfileNoteRowView(
            note: note,
            profile: section == .tagged ? nostrService.profiles[note.pubkey] : profile,
            rowData: data,
            onReply: { onReply(note) },
            onQuote: { onQuote(note) },
            onProfile: onProfile,
            onMedia: onMedia
        )
        .equatable()
        .onReceive(nostrService.$profileUpdates.dropFirst()) { signal in
            if !signal.pubkeys.isDisjoint(with: people) { profilesSeen &+= 1 }
        }
    }

    /// Everyone whose name or picture this row draws.
    private var people: Set<String> {
        var people: Set<String> = [note.pubkey, feedService.originalNote(for: note).pubkey]
        if let reposter = note.repostedBy { people.insert(reposter) }
        if let repliedTo = note.replyToPubkey { people.insert(repliedTo) }
        if let parent = note.parentEventId.flatMap({ feedService.findNote(id: $0) }) {
            people.insert(parent.pubkey)
        }
        return people
    }
}

/// The row as drawn. Equatable on what it shows; the closures are left out,
/// they only reach the page's own state.
struct ProfileNoteRowView: View, Equatable {
    let note: FeedNote
    let profile: FeedProfile?
    let rowData: FeedNoteRowData
    let onReply: () -> Void
    let onQuote: () -> Void
    let onProfile: (String) -> Void
    let onMedia: (URL, [URL]) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.note == rhs.note && lhs.profile == rhs.profile && lhs.rowData == rhs.rowData
    }

    var body: some View {
        FeedNoteRow(
            note: note,
            profile: profile,
            rowData: rowData,
            onReply: onReply,
            onQuote: onQuote,
            onProfile: onProfile,
            onMedia: onMedia,
            showParent: false
        )
    }
}

/// What a profile row reads besides its note, as one throttled signal: the
/// account's likes, reactions, reposts and zaps, fetched originals and
/// parents, the profile numbers and the zap settings. Shared by every row;
/// only rows on screen exist to hear it.
@MainActor
final class ProfileRowSignals: ObservableObject {
    static let shared = ProfileRowSignals()
    private var cancellable: AnyCancellable?

    private init() {
        let feed = FeedService.shared
        let config = ConfigService.shared
        // dropFirst: each @Published sends its current value on subscribe.
        let changes: [AnyPublisher<Void, Never>] = [
            feed.$likedEventIds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$myReactions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$repostedEventIds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$zappedEventIds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$parentNotesCache.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$followedPubkeys.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ProfileEngagementStore.shared.$ledgers.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            config.$config.map { [$0.nwcURI.isEmpty ? 0 : 1, $0.defaultZapAmount, $0.zapsOnlyMode ? 1 : 0] }
                .removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published fires before the value is stored; the throttle delivers
        // on the next run loop pass, after it is. The first change in a burst
        // goes through at once, so a like still shows straight away.
        cancellable = Publishers.MergeMany(changes)
            .throttle(for: .milliseconds(150), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.objectWillChange.send() }
    }
}

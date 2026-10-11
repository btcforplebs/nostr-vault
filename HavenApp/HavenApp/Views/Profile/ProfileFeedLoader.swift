import SwiftUI
import Combine

/// One profile's notes, the notes that tag it, its kind 0 and contact list,
/// and its followers, streamed from the relays it is likely to be on and paged
/// back as the tabs scroll. Shared by your own profile and everyone else's;
/// the screens differ, the loading does not.
@MainActor
final class ProfileFeedLoader: ObservableObject {
    let pubkey: String
    /// Your own profile counts followers from your relay's ledger, which is
    /// complete, and lists who you follow from the feed's own follow list.
    /// Anyone else's come from what the relays return.
    let usesOwnLedger: Bool

    init(pubkey: String, usesOwnLedger: Bool) {
        self.pubkey = pubkey
        self.usesOwnLedger = usesOwnLedger
        // "Delete file and post" from a Media tile takes the post down; drop
        // it here too, or its tile stays up showing a missing file.
        deletedObserver = NotificationCenter.default.publisher(for: .havenOwnEventsDeleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let ids = note.object as? Set<String> else { return }
                self.profileNotes.removeAll { ids.contains($0.id) }
                self.rebucket()
            }
    }

    var nostrService: NostrService { .shared }
    var feedService: FeedService { .shared }
    var config: HavenConfig { ConfigService.shared.config }
    private var deletedObserver: AnyCancellable?

    // MARK: - What the screen reads

    @Published var selectedSection: ProfileSection = .notes

    @Published private(set) var profileNotes: [FeedNote] = []
    @Published private(set) var taggedNotes: [FeedNote] = []
    /// The lists the tabs and counts read, worked out once per change to the
    /// notes rather than many times on every redraw.
    @Published private(set) var buckets = ProfileNoteBuckets()
    @Published var isLoadingNotes = false
    /// False until the first load starts, so the first frame reads
    /// "Loading…" rather than "No notes yet".
    @Published var notesLoadStarted = false
    @Published var isLoadingOlderNotes = false
    @Published var hasMoreNotes = true
    @Published var isLoadingOlderTaggedNotes = false
    @Published var hasMoreTaggedNotes = true

    // Following / followers
    @Published var followingCount: Int?
    @Published var followsMe = false
    /// This profile's follows, in contact-list order (other profiles only;
    /// your own come from the feed's follow list).
    @Published var followingList: [String] = []
    @Published var followersCount: Int?
    /// Follower → created_at of their list naming this profile.
    @Published var followerSeenAt: [String: Int64] = [:]
    @Published var followersExhausted = false
    /// Finished follower pages; the list's loader is keyed on it so it asks
    /// again after a page that brought nobody new.
    @Published var followerPagesDone = 0
    /// Largest NIP-45 COUNT any relay gave for this profile's followers.
    @Published var relayFollowerCount: Int?
    /// Vertex's count, the one npub.world shows. Preferred when it answers.
    @Published var vertexFollowerCount: Int?
    /// Your own followers on your relay's ledger, spam left out: the list the
    /// FOLLOWERS button opens and the Vault's Followers tab, so the header
    /// shows the same number. Only set when `usesOwnLedger`.
    @Published var ownLedgerCount: Int?

    // MARK: - Bookkeeping

    var followerPubkeys = Set<String>()
    var followerPageSubId: String?
    var followerPageToken = 0
    var followerPageAnswers = 0
    var followerPageExpected = 0
    var followerPageCountBefore = 0
    var quietFollowerPages = 0
    /// created_at of the kind 0 and kind 3 now shown. Each relay answers with
    /// its own copy and the answers arrive in any order, so an older copy from
    /// a slow relay must not replace a newer one already on screen.
    var shownMetadataAt: Int64 = 0
    var shownContactsAt: Int64 = 0

    /// Bumped by each opening load, so the fallback timer of an earlier load
    /// cannot end a later one early.
    var notesLoadToken = 0
    /// Relays of the opening load that have not answered yet (EOSE, CLOSED or
    /// a failed connection). Loading ends when the last one answers, not the
    /// first: the phone's own relay always answers first, and for someone
    /// else it usually has nothing.
    var openingPending = Set<Int>()
    /// Notes received but not yet on screen. They go in together a moment
    /// later, in one sort and one redraw, instead of one of each per event.
    let pending = PendingProfileNotes()
    var profileClients: [WebSocketClient] = []
    var profileCancellables = Set<AnyCancellable>()
    var seenNoteIds = Set<String>()

    // Paging bookkeeping. A "page" is one round of `older-` REQs sent to every
    // connected relay under a single subscription id; it completes when they have
    // all answered (EOSE or CLOSED), or when the fallback timer fires — whichever
    // comes first. The token guards against a late timer finishing a newer page.
    var olderPageToken = 0
    var olderPageSubId: String?
    var olderPageAnswers = 0
    var olderPageExpected = 0
    var olderPageCountBefore = 0
    var olderPageVisibleBefore = 0
    var olderPageSection: ProfileSection = .notes
    var quietOlderPages = 0
    var autoPagedInARow = 0

    // Tagged notes (notes by others that tag/mention/repost/quote this user)
    var seenTaggedIds = Set<String>()
    var olderTaggedToken = 0
    var olderTaggedSubId: String?
    var olderTaggedAnswers = 0
    var olderTaggedExpected = 0
    var olderTaggedCountBefore = 0
    var olderTaggedVisibleBefore = 0
    var quietOlderTaggedPages = 0
    var autoPagedTaggedInARow = 0

    // MARK: - Ordering

    /// A TOTAL order: newest first, ties broken by id. Sorting on the timestamp
    /// alone leaves same-second notes in arrival order, which reshuffles on every
    /// event that lands, and makes `profileNotes.last` — the anchor every `until`
    /// page is built on — an arbitrary member of the tie group. At a page boundary
    /// that drops one note and re-requests another.
    private static func newestFirst(_ a: FeedNote, _ b: FeedNote) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id > b.id
    }

    /// Splits the notes into the tab lists. `mediaURLs` scans each note's
    /// text, so this runs when the notes change, never from `body`.
    /// Reposts get their own tab; everything else is a post or a reply.
    /// Media is this person's own pictures and video, posted or replied
    /// with — a repost's media is someone else's, so it stays out.
    /// Articles have their own tab (`ProfileExtrasLoader`, newest version of
    /// each); listing every saved version here too showed them twice.
    private func rebucket() {
        var top: [FeedNote] = [], media: [FeedNote] = []
        var replies: [FeedNote] = [], reposts: [FeedNote] = []
        for note in profileNotes {
            if note.kind == 6 {
                reposts.append(note)
                continue
            }
            if note.kind == 30023 { continue }
            if note.isReply { replies.append(note) } else { top.append(note) }
            if !note.mediaURLs.isEmpty { media.append(note) }
        }
        buckets = ProfileNoteBuckets(
            top: top,
            media: media,
            replies: replies,
            reposts: reposts,
            tagged: taggedNotes.filter { $0.pubkey != pubkey }
        )
    }

    func scheduleFlush() {
        guard !pending.scheduled else { return }
        pending.scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flushPendingNotes() }
    }

    /// Puts the waiting notes on screen. Anything that reads the lists to
    /// decide something (paging, end of loading) flushes first.
    func flushPendingNotes() {
        pending.scheduled = false
        guard !pending.notes.isEmpty || !pending.tagged.isEmpty else { return }
        if !pending.notes.isEmpty {
            profileNotes.append(contentsOf: pending.notes)
            profileNotes.sort(by: Self.newestFirst)
            pending.notes.removeAll()
        }
        if !pending.tagged.isEmpty {
            taggedNotes.append(contentsOf: pending.tagged)
            taggedNotes.sort(by: Self.newestFirst)
            pending.tagged.removeAll()
        }
        rebucket()
    }

    // MARK: - Tabs

    func notes(for section: ProfileSection) -> [FeedNote] {
        switch section {
        case .notes: return buckets.top
        case .media: return buckets.media
        case .replies: return buckets.replies
        case .reposts: return buckets.reposts
        case .tagged: return buckets.tagged
        case .shop, .articles, .divines, .music: return []
        }
    }

    var currentSectionNotes: [FeedNote] { notes(for: selectedSection) }

    /// True until paging has found no older notes. A short profile shows the
    /// sentinel at once, so it pages to the end and drops the "+" quickly.
    func hasMore(for section: ProfileSection) -> Bool {
        switch section {
        case .notes, .media, .replies, .reposts: return hasMoreNotes
        case .tagged: return hasMoreTaggedNotes
        default: return false
        }
    }

    /// More may be older AND there is a note to page back from. A profile
    /// with nothing at all has no anchor, so it has nothing to look back for.
    func canPageOlder(for section: ProfileSection) -> Bool {
        guard hasMore(for: section), !profileClients.isEmpty else { return false }
        return section == .tagged ? !taggedNotes.isEmpty : !profileNotes.isEmpty
    }

    func isLoadingOlder(for section: ProfileSection) -> Bool {
        section == .tagged ? isLoadingOlderTaggedNotes : isLoadingOlderNotes
    }

    /// Asks for the page before the oldest note of the tab's own stream.
    func loadOlder(for section: ProfileSection) {
        if section == .tagged { loadOlderTaggedNotes() } else { loadOlderProfileNotes() }
    }

    /// Automatic pages already spent on each empty tab. Capped so a tab that
    /// is empty for good (someone who never reposts) cannot walk the whole
    /// archive on its own; past the cap the tab offers "Look further back".
    private var emptyTabPages: [ProfileSection: Int] = [:]

    /// An empty tab is on screen with nothing in flight: page back for it,
    /// up to 8 pages. Called again each time a page finishes, so a tab
    /// chosen while another tab's page was loading still gets its turn.
    func autoPageEmptyTab(_ section: ProfileSection) {
        guard notes(for: section).isEmpty, canPageOlder(for: section),
              !isLoadingOlder(for: section) else { return }
        let spent = emptyTabPages[section, default: 0]
        guard spent < 8 else { return }
        emptyTabPages[section] = spent + 1
        loadOlder(for: section)
    }

    // MARK: - Follow counts

    /// Your own profile shows your relay's ledger, so the header matches the
    /// list it opens and the Vault. Anyone else: Vertex counts follow lists
    /// from across Nostr, once per follower, so its answer wins. Without it: the streamed kind-3 events stop at 100
    /// per relay, so they undercount anyone with more followers. Relays that
    /// answer NIP-45 COUNT give the full number; show whichever is larger.
    var displayedFollowersCount: Int? {
        if usesOwnLedger, let ownLedgerCount { return ownLedgerCount }
        if let vertexFollowerCount { return vertexFollowerCount }
        switch (relayFollowerCount, followersCount) {
        case let (relay?, streamed?): return max(relay, streamed)
        case let (relay, streamed): return relay ?? streamed
        }
    }

    /// Who this profile follows: your own from the feed's follow list, which
    /// is the one you edit; anyone else's from their newest contact list.
    var followingPubkeys: [String] {
        usesOwnLedger ? feedService.followedPubkeys.filter { $0 != pubkey } : followingList
    }

    var followingCountShown: Int? {
        usesOwnLedger ? feedService.followedPubkeys.filter { $0 != pubkey }.count : followingCount
    }
}

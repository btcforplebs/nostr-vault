import SwiftUI
import Combine

/// A profile's tabs. The five every profile has come first; the ones that only
/// show once this person's articles, diVines, music or listings arrive go after
/// them, so a late tab never pushes an earlier one along.
enum ProfileSection: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case media = "Media"
    case replies = "Replies"
    case reposts = "Reposts"
    case tagged = "Tagged"
    case articles = "Articles"
    case divines = "diVines"
    case music = "Music"
    case shop = "Shop"
    var id: String { rawValue }

    /// The feed types' own icons, so a tab reads the same as the feed it
    /// matches. Tabs are icons only; the name is the accessibility label
    /// and, on the Mac, the tooltip.
    var symbol: String {
        switch self {
        case .notes: return "text.bubble"
        case .media: return FeedMode.media.symbolName
        case .replies: return "arrowshape.turn.up.left"
        case .reposts: return "arrow.2.squarepath"
        case .articles: return FeedMode.articles.symbolName
        case .divines: return FeedMode.reels.symbolName
        case .music: return FeedMode.music.symbolName
        case .tagged: return "at"
        case .shop: return FeedMode.marketplace.symbolName
        }
    }

    /// The tabs filled from the profile's own note stream.
    var isNoteTab: Bool {
        switch self {
        case .notes, .media, .replies, .reposts, .tagged: return true
        default: return false
        }
    }
}

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

    private var nostrService: NostrService { .shared }
    private var feedService: FeedService { .shared }
    private var config: HavenConfig { ConfigService.shared.config }
    private var deletedObserver: AnyCancellable?

    // MARK: - What the screen reads

    @Published var selectedSection: ProfileSection = .notes

    @Published private(set) var profileNotes: [FeedNote] = []
    @Published private(set) var taggedNotes: [FeedNote] = []
    /// The lists the tabs and counts read, worked out once per change to the
    /// notes rather than many times on every redraw.
    @Published private(set) var buckets = ProfileNoteBuckets()
    @Published private(set) var isLoadingNotes = false
    /// False until the first load starts, so the first frame reads
    /// "Loading…" rather than "No notes yet".
    @Published private(set) var notesLoadStarted = false
    @Published private(set) var isLoadingOlderNotes = false
    @Published private(set) var hasMoreNotes = true
    @Published private(set) var isLoadingOlderTaggedNotes = false
    @Published private(set) var hasMoreTaggedNotes = true

    // Following / followers
    @Published private(set) var followingCount: Int?
    @Published private(set) var followsMe = false
    /// This profile's follows, in contact-list order (other profiles only;
    /// your own come from the feed's follow list).
    @Published private(set) var followingList: [String] = []
    @Published private(set) var followersCount: Int?
    /// Follower → created_at of their list naming this profile.
    @Published private(set) var followerSeenAt: [String: Int64] = [:]
    @Published private(set) var followersExhausted = false
    /// Finished follower pages; the list's loader is keyed on it so it asks
    /// again after a page that brought nobody new.
    @Published private(set) var followerPagesDone = 0
    /// Largest NIP-45 COUNT any relay gave for this profile's followers.
    @Published private(set) var relayFollowerCount: Int?
    /// Vertex's count, the one npub.world shows. Preferred when it answers.
    @Published private(set) var vertexFollowerCount: Int?
    /// Your own followers on your relay's ledger, spam left out: the list the
    /// FOLLOWERS button opens and the Vault's Followers tab, so the header
    /// shows the same number. Only set when `usesOwnLedger`.
    @Published private(set) var ownLedgerCount: Int?

    // MARK: - Bookkeeping

    private var followerPubkeys = Set<String>()
    private var followerPageSubId: String?
    private var followerPageToken = 0
    private var followerPageAnswers = 0
    private var followerPageExpected = 0
    private var followerPageCountBefore = 0
    private var quietFollowerPages = 0
    /// created_at of the kind 0 and kind 3 now shown. Each relay answers with
    /// its own copy and the answers arrive in any order, so an older copy from
    /// a slow relay must not replace a newer one already on screen.
    private var shownMetadataAt: Int64 = 0
    private var shownContactsAt: Int64 = 0

    /// Bumped by each opening load, so the fallback timer of an earlier load
    /// cannot end a later one early.
    private var notesLoadToken = 0
    /// Relays of the opening load that have not answered yet (EOSE, CLOSED or
    /// a failed connection). Loading ends when the last one answers, not the
    /// first: the phone's own relay always answers first, and for someone
    /// else it usually has nothing.
    private var openingPending = Set<Int>()
    /// Notes received but not yet on screen. They go in together a moment
    /// later, in one sort and one redraw, instead of one of each per event.
    private let pending = PendingProfileNotes()
    private var profileClients: [WebSocketClient] = []
    private var profileCancellables = Set<AnyCancellable>()
    private var seenNoteIds = Set<String>()

    // Paging bookkeeping. A "page" is one round of `older-` REQs sent to every
    // connected relay under a single subscription id; it completes when they have
    // all answered (EOSE or CLOSED), or when the fallback timer fires — whichever
    // comes first. The token guards against a late timer finishing a newer page.
    private var olderPageToken = 0
    private var olderPageSubId: String?
    private var olderPageAnswers = 0
    private var olderPageExpected = 0
    private var olderPageCountBefore = 0
    private var olderPageVisibleBefore = 0
    private var olderPageSection: ProfileSection = .notes
    private var quietOlderPages = 0
    private var autoPagedInARow = 0

    // Tagged notes (notes by others that tag/mention/repost/quote this user)
    private var seenTaggedIds = Set<String>()
    private var olderTaggedToken = 0
    private var olderTaggedSubId: String?
    private var olderTaggedAnswers = 0
    private var olderTaggedExpected = 0
    private var olderTaggedCountBefore = 0
    private var olderTaggedVisibleBefore = 0
    private var quietOlderTaggedPages = 0
    private var autoPagedTaggedInARow = 0

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

    private func scheduleFlush() {
        guard !pending.scheduled else { return }
        pending.scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flushPendingNotes() }
    }

    /// Puts the waiting notes on screen. Anything that reads the lists to
    /// decide something (paging, end of loading) flushes first.
    private func flushPendingNotes() {
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
        guard hasMore(for: section) else { return false }
        return section == .tagged ? !taggedNotes.isEmpty : !profileNotes.isEmpty
    }

    func isLoadingOlder(for section: ProfileSection) -> Bool {
        section == .tagged ? isLoadingOlderTaggedNotes : isLoadingOlderNotes
    }

    /// Asks for the page before the oldest note of the tab's own stream.
    func loadOlder(for section: ProfileSection) {
        if section == .tagged { loadOlderTaggedNotes() } else { loadOlderProfileNotes() }
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

    // MARK: - Loading

    /// Where this person's articles and diVines are likely to be: the relays
    /// the profile reads, their outbox, and diVine's own relay.
    var extrasRelays: [URL] {
        var strings: [String] = []
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            strings.append(config.nostrURL)
        }
        strings += config.readRelays.prefix(3)
        strings += (nostrService.outboxRelays[pubkey] ?? []).prefix(3)
        strings.append(ReelsFeedService.divineRelay)
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }.compactMap { URL(string: $0) }
    }

    /// The page came on screen: header, notes and counts.
    func start() {
        nostrService.fetchMissingProfiles(for: [pubkey])
        fetchAuthorNotes()
        fetchFollowerCount()
    }

    /// The page went away. Loads in flight die with their connections;
    /// without this a return before the first EOSE skips the notes load
    /// entirely.
    func stop() {
        disconnectClients()
        isLoadingNotes = false
        openingPending.removeAll()
        isLoadingOlderNotes = false
        olderPageSubId = nil
        isLoadingOlderTaggedNotes = false
        olderTaggedSubId = nil
    }

    /// Reloads in place: everything on screen stays until something newer
    /// replaces it, so the page never blanks and refills. New posts are added
    /// at the top, counts change only when a new number arrives, and the
    /// header, Shop and the extra tabs are fetched again. Returns once every
    /// relay has answered the new load, 8s at most, and not before 0.6s, so a
    /// spinner reads as having done something.
    func refresh(shop: SellerListingsLoader, extras: ProfileExtrasLoader) async {
        let started = Date()
        nostrService.fetchMissingProfiles(for: [pubkey], force: true)
        shop.load(pubkey: pubkey, force: true)
        extras.load(pubkey: pubkey, relays: extrasRelays, force: true)

        // A page of older notes in flight dies with its connection; let the
        // next scroll to the bottom ask again.
        stop()
        fetchAuthorNotes()
        fetchFollowerCount()

        while isLoadingNotes, Date().timeIntervalSince(started) < 8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let shown = Date().timeIntervalSince(started)
        if shown < 0.6 {
            try? await Task.sleep(nanoseconds: UInt64((0.6 - shown) * 1_000_000_000))
        }
    }

    /// Asks each relay for its own follower COUNT and keeps the largest.
    /// Relays hold different subsets of contact lists, so adding their
    /// counts together would double-count; the largest single answer is
    /// the closest to the real number. Your own profile reads the ledger
    /// instead and asks nobody.
    private func fetchFollowerCount() {
        let target = pubkey
        if usesOwnLedger {
            Task { [weak self] in
                let count = await Task.detached(priority: .userInitiated) {
                    FollowerSnapshot.load(owner: target)?.current.count
                }.value
                guard let count else { return }
                self?.ownLedgerCount = count
            }
            return
        }

        var urls: [URL] = []
        var seen = Set<String>()
        // damus and primal answer COUNT; most other popular relays reject it.
        let candidates = ["wss://relay.damus.io", "wss://relay.primal.net"]
            + config.activeFeedRelays.prefix(3)
        for str in candidates where seen.insert(str).inserted {
            if let url = URL(string: str) { urls.append(url) }
        }
        let filter: [String: Any] = ["kinds": [3], "#p": [target]]

        Task { [weak self] in
            guard let count = await NostrService.shared.fetchVertexFollowerCount(target: target) else { return }
            self?.vertexFollowerCount = count
        }
        for url in urls {
            Task { [weak self] in
                guard let count = await NostrService.shared.fetchCount(from: [url], filter: filter) else { return }
                guard let self else { return }
                self.relayFollowerCount = max(self.relayFollowerCount ?? 0, count)
            }
        }
    }

    private func fetchAuthorNotes() {
        guard !isLoadingNotes else { return }
        isLoadingNotes = true
        notesLoadStarted = true

        let existing = feedService.notes.filter { $0.pubkey == pubkey }
        for note in existing {
            if !seenNoteIds.contains(note.id) {
                seenNoteIds.insert(note.id)
                pending.notes.append(note)
            }
        }
        flushPendingNotes()

        var relayURLs: [URL] = []
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            if let local = URL(string: config.nostrURL) {
                relayURLs.append(local)
            }
        }
        // Use up to 3 external relays to improve chances of finding the user's data.
        relayURLs.append(contentsOf: config.readRelays.prefix(3).compactMap { URL(string: $0) })

        // NIP-65 outbox model: we're fetching events FROM this user, so query their
        // write/outbox relays (where they actually publish), not their read/inbox
        // relays (where others send things TO them).
        if let userRelays = nostrService.outboxRelays[pubkey] {
            let existingStrings = Set(relayURLs.map { $0.absoluteString })
            for relayStr in userRelays.prefix(3) {
                if !existingStrings.contains(relayStr), let url = URL(string: relayStr) {
                    relayURLs.append(url)
                }
            }
        }

        let pubkey = pubkey
        let notesFilter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "authors": [pubkey],
            "limit": 50
        ]
        let profileFilter: [String: Any] = ["kinds": [0], "authors": [pubkey], "limit": 1]
        let contactFilter: [String: Any] = ["kinds": [3], "authors": [pubkey], "limit": 1]
        let taggedFilter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "#p": [pubkey],
            "limit": 50
        ]
        var filters: [Any] = [notesFilter, profileFilter, contactFilter]
        // Your own followers come from the ledger; asking the relays for a
        // sample of them too only cost a hundred events nobody reads.
        if !usesOwnLedger {
            filters.append(["kinds": [3], "#p": [pubkey], "limit": 100] as [String: Any])
        }
        filters.append(taggedFilter)

        openingPending = Set(relayURLs.indices)
        for (relay, url) in relayURLs.enumerated() {
            let client = WebSocketClient()
            profileClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handleProfileNoteMessage(message, relay: relay)
                }
                .store(in: &profileCancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    // A relay that can't be reached has answered too: it
                    // will send nothing.
                    if state == .error { self?.openingRelayAnswered(relay) }
                    if state == .connected {
                        let req: [Any] = ["REQ", "profile-\(UUID().uuidString.prefix(6))"] + filters
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client?.send(text: str)
                        }
                    }
                }
                .store(in: &profileCancellables)

            client.connect(url: url)
        }

        notesLoadToken += 1
        let token = notesLoadToken
        if relayURLs.isEmpty { isLoadingNotes = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, token == self.notesLoadToken else { return }
            self.flushPendingNotes()
            self.openingPending.removeAll()
            self.isLoadingNotes = false
        }
    }

    private func openingRelayAnswered(_ relay: Int) {
        guard openingPending.remove(relay) != nil else { return }
        if openingPending.isEmpty {
            flushPendingNotes()
            isLoadingNotes = false
        }
    }

    private func handleProfileNoteMessage(_ message: String, relay: Int) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }

        if type == "EVENT", json.count >= 3,
           let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            // Handle kind 0 (profile metadata) from the target user
            if event.kind == 0, event.pubkey == pubkey {
                guard event.created_at >= shownMetadataAt else { return }
                shownMetadataAt = event.created_at
                if let result = ProfileRepository.parseMetadataContent(
                    event.content, pubkey: pubkey,
                    existingProfile: nostrService.profiles[pubkey],
                    createdAt: event.created_at
                ), result.changed {
                    nostrService.profiles[pubkey] = result.profile
                }
                return
            }

            if event.kind == 3 {
                let pTags = event.tags.filter { $0.count >= 2 && $0[0] == "p" }
                if event.pubkey == pubkey {
                    guard event.created_at >= shownContactsAt else { return }
                    shownContactsAt = event.created_at
                    // This user's own contact list → extract following count and followsMe.
                    // followsMe is true if they follow ANY of our accounts (owner or
                    // whitelisted) so the badge is consistent across account switches.
                    var seenTags = Set<String>()
                    let list = pTags.map { $0[1] }.filter { $0 != pubkey && seenTags.insert($0).inserted }
                    followingList = list
                    followingCount = pTags.filter { $0[1] != pubkey }.count
                    let ourHexKeys: Set<String> = Set(ConfigService.shared.allAccountNpubs.compactMap { Bech32.decode($0)?.hexString })
                    if !ourHexKeys.isEmpty {
                        followsMe = pTags.contains { ourHexKeys.contains($0[1]) }
                    }
                } else {
                    // Someone else's contact list containing this pubkey → they follow this user
                    followerPubkeys.insert(event.pubkey)
                    followersCount = followerPubkeys.count
                    followerSeenAt[event.pubkey] = max(followerSeenAt[event.pubkey] ?? 0, event.created_at)
                }
                return
            }

            // Check if this is a tagged event (authored by someone else, but p-tagging the profile user)
            let isTaggedEvent = event.pubkey != pubkey &&
                [1, 6, 30023, NIP88Poll.kind].contains(event.kind) &&
                event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey })

            if isTaggedEvent {
                guard !seenTaggedIds.contains(event.id) else { return }
                seenTaggedIds.insert(event.id)

                pending.tagged.append(FeedNote(
                    id: event.id,
                    pubkey: event.pubkey,
                    content: event.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                    tags: event.tags,
                    kind: event.kind
                ))
                scheduleFlush()

                // Fetch profile for the tagger
                if nostrService.profiles[event.pubkey] == nil {
                    nostrService.fetchMissingProfiles(for: [event.pubkey])
                }

                // Trigger fetch of the original note for empty-content reposts
                if event.kind == 6 && event.content.isEmpty,
                   let refId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                    feedService.fetchMissingNote(id: refId)
                }

                return
            }

            // For notes (kind 1, 6, 30023), only show from the target user
            guard event.pubkey == pubkey else { return }

            guard !seenNoteIds.contains(event.id) else { return }
            seenNoteIds.insert(event.id)

            pending.notes.append(FeedNote(
                id: event.id,
                pubkey: event.pubkey,
                content: event.content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                tags: event.tags,
                kind: event.kind
            ))
            scheduleFlush()

            // Trigger fetch of the original note for empty-content reposts
            if event.kind == 6 && event.content.isEmpty,
               let refId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                feedService.fetchMissingNote(id: refId)
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" || type == "CLOSED" {
            // CLOSED counts the same as EOSE: the relay is saying it will send
            // nothing more under this subscription. A refusal (sub cap, rate limit)
            // reads identically to an exhausted history from here, and ignoring it
            // left the page hanging on a relay that was never going to answer.
            let subId = (json.count >= 2 ? json[1] as? String : nil) ?? ""
            // Page bookkeeping counts the lists, so they must be complete.
            flushPendingNotes()
            if subId.hasPrefix("followers-page-") {
                guard subId == followerPageSubId else { return }
                followerPageAnswers += 1
                if followerPageAnswers >= followerPageExpected {
                    finishFollowerPage(token: followerPageToken)
                }
            } else if subId.hasPrefix("older-tagged-") {
                guard subId == olderTaggedSubId else { return }
                olderTaggedAnswers += 1
                if olderTaggedAnswers >= olderTaggedExpected {
                    finishOlderTaggedPage(token: olderTaggedToken)
                }
            } else if subId.hasPrefix("older-") {
                guard subId == olderPageSubId else { return }
                olderPageAnswers += 1
                if olderPageAnswers >= olderPageExpected {
                    finishOlderPage(token: olderPageToken)
                }
            } else {
                // The opening subscription is deliberately left open — it is also
                // how new posts reach the profile while it is on screen.
                openingRelayAnswered(relay)
            }
        }
    }

    // MARK: - Follower pages

    /// Asks every relay for the next 100 lists naming this profile, older
    /// than the oldest already seen.
    func loadMoreFollowers() {
        guard followerPageSubId == nil, !followersExhausted, !profileClients.isEmpty,
              let oldest = followerSeenAt.values.min() else { return }
        followerPageToken &+= 1
        let token = followerPageToken
        let subId = "followers-page-\(UUID().uuidString.prefix(6))"
        followerPageSubId = subId
        followerPageAnswers = 0
        followerPageExpected = profileClients.count
        followerPageCountBefore = followerSeenAt.count
        let filter: [String: Any] = ["kinds": [3], "#p": [pubkey], "until": Int(oldest) - 1, "limit": 100]
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let str = String(data: data, encoding: .utf8) else {
            followerPageSubId = nil
            return
        }
        for client in profileClients { client.send(text: str) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finishFollowerPage(token: token) }
    }

    private func finishFollowerPage(token: Int) {
        guard token == followerPageToken, let subId = followerPageSubId else { return }
        closeProfileSubscription(subId)
        followerPageSubId = nil
        if followerSeenAt.count > followerPageCountBefore {
            quietFollowerPages = 0
        } else {
            // Two empty rounds in a row, not one: a single quiet round is more
            // often a slow relay than the end of the list.
            quietFollowerPages += 1
            if quietFollowerPages >= 2 { followersExhausted = true }
        }
        followerPagesDone += 1
    }

    // MARK: - Note pages

    private func loadOlderProfileNotes() {
        guard !isLoadingOlderNotes, hasMoreNotes else { return }
        flushPendingNotes()
        guard let oldest = profileNotes.last else { return }
        guard !profileClients.isEmpty else { return }
        isLoadingOlderNotes = true

        olderPageToken &+= 1
        let token = olderPageToken
        let subId = "older-\(UUID().uuidString.prefix(6))"
        olderPageSubId = subId
        olderPageAnswers = 0
        olderPageExpected = profileClients.count
        olderPageCountBefore = profileNotes.count
        olderPageVisibleBefore = currentSectionNotes.count
        olderPageSection = selectedSection

        let filter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "authors": [pubkey],
            "until": Int(oldest.createdAt.timeIntervalSince1970),
            "limit": 50
        ]
        // One subscription id for the whole page, so every relay's answer counts
        // toward the same page and the CLOSE below releases all of them.
        let req: [Any] = ["REQ", subId, filter]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            isLoadingOlderNotes = false
            return
        }
        for client in profileClients {
            client.send(text: str)
        }

        // Fallback only. Normally the page finishes when every relay has answered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finishOlderPage(token: token)
        }
    }

    private func finishOlderPage(token: Int) {
        guard token == olderPageToken, isLoadingOlderNotes else { return }
        flushPendingNotes()
        isLoadingOlderNotes = false
        if let subId = olderPageSubId {
            closeProfileSubscription(subId)
            olderPageSubId = nil
        }

        let grew = profileNotes.count > olderPageCountBefore
        let visibleGrew = currentSectionNotes.count > olderPageVisibleBefore

        if grew {
            quietOlderPages = 0
        } else {
            // One quiet round is a slow relay far more often than an exhausted
            // history. Only a second empty round in a row ends paging — the old
            // code latched this off after a single 5s window and never reset it,
            // so one slow relay killed paging for the life of the screen.
            quietOlderPages += 1
            if quietOlderPages >= 2 { hasMoreNotes = false }
        }

        // The scroll sentinel only fires again when the VISIBLE list grows. A page
        // that was entirely replies adds nothing to the Notes tab, so paging would
        // stop with history still left. Carry on ourselves — bounded, so one flick
        // of the scroll cannot walk the whole archive.
        guard hasMoreNotes,
              !visibleGrew,
              olderPageSection == selectedSection,
              autoPagedInARow < 8 else {
            autoPagedInARow = 0
            return
        }
        autoPagedInARow += 1
        loadOlderProfileNotes()
    }

    /// The paging subscriptions are one-shot, but nothing ever released them.
    /// Every page leaked one on every relay, and relays that cap concurrent REQs
    /// start refusing — which this screen then read as "no more notes".
    private func closeProfileSubscription(_ subId: String) {
        let msg: [Any] = ["CLOSE", subId]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        for client in profileClients {
            client.send(text: str)
        }
    }

    private func loadOlderTaggedNotes() {
        guard !isLoadingOlderTaggedNotes, hasMoreTaggedNotes else { return }
        flushPendingNotes()
        guard let oldest = taggedNotes.last else { return }
        guard !profileClients.isEmpty else { return }
        isLoadingOlderTaggedNotes = true

        olderTaggedToken &+= 1
        let token = olderTaggedToken
        let subId = "older-tagged-\(UUID().uuidString.prefix(6))"
        olderTaggedSubId = subId
        olderTaggedAnswers = 0
        olderTaggedExpected = profileClients.count
        olderTaggedCountBefore = taggedNotes.count
        olderTaggedVisibleBefore = buckets.tagged.count

        let filter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "#p": [pubkey],
            "until": Int(oldest.createdAt.timeIntervalSince1970),
            "limit": 50
        ]
        let req: [Any] = ["REQ", subId, filter]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            isLoadingOlderTaggedNotes = false
            return
        }
        for client in profileClients {
            client.send(text: str)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finishOlderTaggedPage(token: token)
        }
    }

    private func finishOlderTaggedPage(token: Int) {
        guard token == olderTaggedToken, isLoadingOlderTaggedNotes else { return }
        flushPendingNotes()
        isLoadingOlderTaggedNotes = false
        if let subId = olderTaggedSubId {
            closeProfileSubscription(subId)
            olderTaggedSubId = nil
        }

        let grew = taggedNotes.count > olderTaggedCountBefore
        // Tagged hides the profile owner's own notes, so a page can grow the pool
        // without adding a single visible row — same stall as the Notes tab.
        let visibleGrew = buckets.tagged.count > olderTaggedVisibleBefore

        if grew {
            quietOlderTaggedPages = 0
        } else {
            quietOlderTaggedPages += 1
            if quietOlderTaggedPages >= 2 { hasMoreTaggedNotes = false }
        }

        guard hasMoreTaggedNotes,
              !visibleGrew,
              selectedSection == .tagged,
              autoPagedTaggedInARow < 8 else {
            autoPagedTaggedInARow = 0
            return
        }
        autoPagedTaggedInARow += 1
        loadOlderTaggedNotes()
    }

    private func disconnectClients() {
        for client in profileClients {
            client.disconnect()
        }
        profileClients.removeAll()
        profileCancellables.removeAll()
    }
}

import Foundation
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted when FeedService injects external events into the local relay.
    /// Replaces the old `.macRelaySyncComplete` notification.
    static let feedInjectionComplete = Notification.Name("feedInjectionComplete")
}


/// Builds a following feed by querying BOTH the local Haven relay and
/// well-known public Nostr relays in parallel.
/// - Local relay: fast, already has notes the inbox received from the network.
/// - External relays: fills in notes not yet mirrored to the local relay.
/// All results share a deduplication set so events never appear twice.
@MainActor
class FeedService: ObservableObject {
    static let shared = FeedService()

    @Published var feedMode: FeedMode = {
        let stored = ConfigService.shared.config.defaultFeedMode.lowercased()
        return FeedMode.allCases.first { $0.rawValue.lowercased() == stored } ?? .following
    }()
    /// True when the feed was auto-switched from Following → curated Global because
    /// the user has no follows yet. Cleared on the first follow action so the
    /// feed reverts to Following automatically.
    var didAutoSwitchToCurated = false
    @Published var mediaFeedMode: MediaFeedMode = .following
    /// Articles from follows only, or from everyone (filtered by the same
    /// Web of Trust / Everyone setting as Global).
    @Published var articlesFeedMode: MediaFeedMode = .following
    /// Polls' Following / Global, and its Open / Closed / All filter.
    @Published var pollsFeedMode: MediaFeedMode = .following
    @Published var pollStatusFilter: PollStatusFilter = .all
    @Published var notes: [FeedNote] = []
    /// O(1) lookup index for notes by ID. Maintained alongside `notes` mutations.
    var noteIndex: [String: FeedNote] = [:]
    @Published var parentNotesCache: [String: FeedNote] = [:]
    /// Fires when referenced notes (thread parents, kind-6 originals, quoted
    /// notes) arrive and are cached. `parentNotesCache` alone is not a usable
    /// signal for the feed's row-data cache: rows are keyed by the *referencing*
    /// note's id, so a re-render changes nothing. See `ReferencedNoteSignal`.
    @Published private(set) var referencedNoteUpdates = ReferencedNoteSignal()
    private var pendingReferencedNoteIds: Set<String> = []
    private var referencedNoteFlushScheduled = false
    /// Size at which `parentNotesCache` is next trimmed. See handleParentNoteFetch.
    var parentNotesCacheTrimAt = 500
    private var referencedNoteGeneration = 0

    /// Records that a referenced note arrived and schedules a coalesced flush,
    /// so a burst of parents landing together produces one row repair pass.
    /// Main-thread only (every call site is already on the main thread).
    func noteReferencedNoteArrived(_ id: String) {
        pendingReferencedNoteIds.insert(id)
        guard !referencedNoteFlushScheduled else { return }
        referencedNoteFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.referencedNoteFlushScheduled = false
            guard !self.pendingReferencedNoteIds.isEmpty else { return }
            let batch = self.pendingReferencedNoteIds
            self.pendingReferencedNoteIds.removeAll(keepingCapacity: true)
            self.referencedNoteGeneration &+= 1
            self.referencedNoteUpdates = ReferencedNoteSignal(generation: self.referencedNoteGeneration, ids: batch)
        }
    }
    @Published var followedPubkeys: [String] = []
    @Published var extendedNetworkPubkeys: [String] = []
    /// When the extended network was last computed. Used to skip re-fetching within 1 hour.
    var extendedNetworkComputedAt: Date?
    static let extendedNetworkCacheAge: TimeInterval = 3600 // 1 hour
    /// True when the last tally finished on its timeout with a relay still
    /// silent, so it is missing follow lists. Such a result is still used — it
    /// beats an empty discovery feed — but it is only held briefly, rather than
    /// freezing a partial network in place for the full hour.
    var extendedNetworkWasPartial = false
    static let partialExtendedNetworkCacheAge: TimeInterval = 300 // 5 minutes
    @Published var isLoadingContacts = false
    /// True once contact loading has completed at least once (success, empty, or timeout).
    /// Used to gate follow/unfollow so we don't publish before the kind-3 has had a chance to arrive,
    /// and — published, because the view needs it — to keep the Following feed from telling you that
    /// you follow nobody before it has ever asked. See `FollowingFeedState`.
    @Published var hasAttemptedContactLoad = false
    /// The user's real follow list is known for this account (see
    /// ContactManager.loadConfirmsList). Until it is, follow / unfollow never
    /// publish: a timed-out load leaves an empty or partial list in memory,
    /// and publishing it would replace every follow on every relay.
    @Published var contactListConfirmed = false
    @Published var isLoadingExtendedNetwork = false
    @Published var isLoadingPopular = false
    @Published var popularFilter: PopularFilter = .all
    @Published var showPopularEngagement = false
    @Published var isLoadingFeed    = false
    @Published var connectionStatus = "Disconnected"

    @Published var newNoteCount: Int = 0
    @Published var pendingNotes: [FeedNote] = [] {
        didSet { refreshVisiblePendingCount() }
    }
    /// How many of `pendingNotes` the current feed would actually show. The
    /// raw list is unfiltered: in Global with the Web of Trust on, most of it
    /// is outsiders the filter drops, so counting it raw put "12 New Posts"
    /// on a button that revealed nothing. Same rule as Android's
    /// `visiblePendingCount`.
    @Published var visiblePendingCount: Int = 0
    @Published var likedEventIds: Set<String> = []
    /// The emoji (and kind-7 event) behind each entry of `likedEventIds`.
    @Published var myReactions: [String: EngagementTracker.MyReaction] = [:]
    /// Reactions this account deleted; see `InteractionState.retractedReactionIds`.
    var retractedReactionIds: Set<String> = []
    /// Per note, the reaction currently being signed. A tap that changes or
    /// removes it before signing ends replaces the token, and the stale
    /// reaction is then never published.
    var pendingReactionTokens: [String: UUID] = [:]
    @Published var repostedEventIds: Set<String> = []
    @Published var zappedEventIds: [String: Int] = [:]
    /// Per-note engagement counts (replies, reactions, reposts) from relay data.
    @Published var noteStats: [String: NoteStats] = [:]

    // MARK: - Search
    @Published var isSearchActive: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [FeedNote] = []
    @Published var isSearching: Bool = false
    var searchClient: WebSocketClient?
    var searchCancellable: AnyCancellable?
    var searchDebounceWork: DispatchWorkItem?

    // MARK: - Cached Filtered Notes (avoids O(n) filter on every SwiftUI render)
    @Published var filteredNotes: [FeedNote] = []
    @Published var filteredMediaNotes: [FeedNote] = []

    /// Set of note IDs where the parent event is the immediately next item in filteredNotes.
    /// Precomputed to avoid needing `Array(enumerated())` in the view's ForEach.
    var parentIsNextNote: Set<String> = []

    /// Detected language per note id (nil inner value: could not be told).
    /// Only filled while the Global feed is narrowed to some languages.
    var noteLanguageCache: [String: String?] = [:]

    /// Cache of raw event JSON strings for NIP-18 repost embedding.
    /// Key: event ID, Value: complete stringified JSON of the event (includes sig).
    var rawEventCache: [String: String] = [:]
    /// FIFO insertion order for rawEventCache eviction (avoids O(n log n) sort).
    var rawEventCacheOrder: [String] = []
    static let maxRawEventCacheSize = 1000

    // Preserve the original kind 3 content (relay hints) to avoid wiping it on follow/unfollow
    var contactListContent: String = ""
    /// Authoritative full NIP-02 "p" tags from the latest kind-3 event.
    /// Each entry is ["p", hex-pubkey] or ["p", hex-pubkey, relay-url, petname].
    /// `followedPubkeys` is always derived from this array.
    var contactListPTags: [[String]] = []
    /// Count of contacts returned by the last successful relay fetch.
    /// Used by the safety check in `publishContactList()`.
    var lastFetchedContactCount: Int = 0
    /// `created_at` of the contact list we last published or committed locally.
    /// Guards the relay-fetch overwrite: a kind-3 from a relay is only accepted
    /// when its `created_at` is >= this value. Otherwise the relay copy is older
    /// than our latest local edit (e.g. a fresh follow whose publish hasn't
    /// propagated yet) and would silently drop follows — so we keep the local set
    /// and re-publish to heal the network. Persisted in the disk snapshot and the
    /// durable following backup so it survives relaunches and the 7-day snapshot TTL.
    var ownContactListCreatedAt: Int64 = 0
    /// created_at of a contact list every relay refused and that was rolled
    /// back. The local relay still holds it, so a reload must not take it.
    var refusedContactListCreatedAt: Int64?
    /// Account key `ownContactListCreatedAt` currently belongs to. When the active
    /// account changes the guard is reset so a previous account's (higher)
    /// timestamp never blocks the new account's relay copy.
    var ownContactListAccountKey: String = ""

    /// Pubkeys that belong to the user's Web of Trust, loaded from the relay's
    /// cached WOT graph (`wot_cache.json`). Used to filter the GLOBAL feed and
    /// Media tab so only notes/media from WOT members are shown.
    @Published var wotPubkeys: Set<String> = []
    /// For everyone in the graph past your follows, how many of your follows
    /// follow them (the WOT tab's Close layer). nil until the relay's cache
    /// carries them.
    @Published var wotVouches: [String: Int]?
    /// True once the relay's graph file has been read for this account, even
    /// if it named nobody. Separates "the relay has not built a graph yet"
    /// from "the graph is built and empty because you follow nobody".
    @Published var wotCacheRead = false
    /// The wot_cache.json last read (path and modification date), so callers
    /// that find the graph empty only re-read it once the relay has written a
    /// new one. Re-reading on every call re-filtered the whole feed each time
    /// and froze the app on an account with an empty graph.
    var wotCacheStamp: (path: String, modified: Date?)?

    /// Popularity scores returned by the local DVM, keyed by note ID.
    /// Used to sort the Popular feed by engagement rank.
    var popularNoteScores: [String: Double] = [:]

    /// Replies to the Popular and Global posts, fetched only for Threaded View.
    /// Kept out of `notes`: both feeds list top-level posts (the filter drops
    /// replies), so without these a threaded card had nothing under it.
    @Published var feedThreadReplies: [FeedNote] = []
    var threadRepliesRequested: Set<String> = []
    /// Bumped on every reset, so a fetch that outlives its feed's list
    /// can't add replies to the next one.
    var threadRepliesGeneration = 0

    // One client per relay URL
    var feedClients: [String: WebSocketClient] = [:]

    /// Each feed relay's own socket state, keyed by `relayStateKey(_:)`. The
    /// dashboard rows and the dot read this; `connectionStatus` alone only
    /// says whether the feed has notes. Watched outside `cancellables`, which
    /// mode and account switches clear while the sockets stay open.
    @Published var relayStates: [String: WebSocketClient.ConnectionState] = [:]
    var relayStateSinks: [String: AnyCancellable] = [:]

    /// Relay keys whose messageSubject/connectionState sinks are currently live.
    /// A warm account switch calls cancellables.removeAll() but deliberately keeps
    /// feed clients connected (to avoid a full relay reconnect) — that call also
    /// silently orphans those clients' sinks, since removeAll() cancels every
    /// Combine subscription regardless of which relay it belonged to. Without this
    /// tracking, subscribeToAllRelays()'s "already connected, just resend the REQ"
    /// reuse branch has no way to know its sink is gone, so every incoming
    /// EVENT/EOSE on that socket is delivered to zero subscribers and silently
    /// dropped — the new account's feed looks stuck until the loading timeout.
    var subscribedClientKeys = Set<String>()
    var cancellables = Set<AnyCancellable>()
    var seenIds = Set<String>()
    private static let maxSeenIds = 10_000

    /// Rebuild seenIds from currently retained notes once it outgrows the
    /// cap. The set otherwise grows for every note ever observed — a
    /// long-running session accumulates entries for notes evicted long ago.
    func trimSeenIdsIfNeeded() {
        guard seenIds.count > Self.maxSeenIds else { return }
        var retained = Set(notes.map { $0.id })
        retained.formUnion(pendingNotes.map { $0.id })
        retained.formUnion(noteBuffer.map { $0.id })
        seenIds = retained
    }
    /// Timestamp (unix seconds) of the newest event successfully processed.
    /// Used on resume to narrow the relay filter to only the gap period.
    var lastEventTimestamp: Int64 = 0
    /// `lastEventTimestamp` frozen at the start of the current subscription
    /// round so every relay in the round gets the same `since` window (see
    /// `feedSinceAndLimit`).
    var subscriptionRoundSince: Int64 = 0
    var newSinceLastView = Date()
    var eoseCount = 0   // track when all relays return EOSE
    /// Relay keys that have received primary feed EOSE — triggers deferred auxiliary subscriptions.
    var primaryEoseRelays = Set<String>()
    /// Maps primary feed subscription IDs to relay keys for EOSE → auxiliary dispatch.
    var subIdToRelayKey: [String: String] = [:]

    /// The author set the live primary REQ was last sent with, per relay key.
    /// `nil`/absent for a relay key means no live primary subscription exists
    /// there (e.g. we skipped sending because the follow set was empty). This is
    /// the bookkeeping that makes `reconcileFeedSubscriptions()` a true reconcile:
    /// when the authoritative follow set changes we compare against this and only
    /// re-issue the REQ where it has actually drifted.
    var subscribedAuthorsByRelay: [String: [String]] = [:]
    /// Re-entrancy guard — `reconcileFeedSubscriptions()` can be reached from a
    /// Combine sink, a Task continuation, and a view `onAppear` in the same runloop turn.
    var isReconciling = false
    /// Prevents the cold-start empty-contacts background retry from looping.
    var contactRetryScheduled = false

    // Background queue for JSON parsing — keeps the main thread free for UI
    let processingQueue = DispatchQueue(label: "com.haven.feed-processing", qos: .userInitiated)

    // Thread-safe accumulator for background event parsing → main thread delivery.
    // All access is serialized on processingQueue.
    let bgAccumulator = BackgroundAccumulator()

    /// Follows the feed relays don't reach, asked on their own write relays:
    /// extra relay URL → the follows to ask it for. See `FeedOutboxPlan`.
    var outboxPlan: [String: [String]] = [:]

    /// Relays that gave up on connecting (three errors) and have not connected
    /// since. Kept across load rounds, unlike `relayErrorCounts`, so the plan
    /// stops counting a dead feed relay as reaching anyone.
    var downRelayKeys = Set<String>()

    /// Authors per trusted-author REQ; relays reject very large filters.
    static let trustedAuthorsCap = 500

    var curatedGraphPollAttempts = 0
    var curatedGraphPollTimer: Timer?

/// In-memory per-account feed snapshots keyed by `activeAccountNpub`
    /// (empty string for the default/owner account). Captured before each
    /// account switch and restored when switching back, so re-switching is
    /// instant and the relay top-up runs as a background refresh.
    var accountSnapshots: [String: AccountFeedSnapshot] = [:]

    /// The last notes of each feed you switched away from, so switching back
    /// shows them at once and only asks relays for what is newer. Keyed by
    /// account + feed (+ the media/articles scope), so nothing crosses
    /// accounts. In memory only; Popular is kept as-is, the others top up.
    struct ModeFeedCache {
        var notes: [FeedNote]
        var parentNotesCache: [String: FeedNote]
        var noteStats: [String: NoteStats]
        var popularNoteScores: [String: Double]
        var capturedAt: Date
    }
    var modeCaches: [String: ModeFeedCache] = [:]
    /// Older than this, a cached feed is dropped and the feed loads cold.
    static let modeCacheMaxAge: TimeInterval = 15 * 60
    /// Popular is computed, not streamed; within this it is shown as cached
    /// with no recompute.
    static let popularCacheFreshFor: TimeInterval = 5 * 60
    /// Feeds with their own service stay connected this long after you leave,
    /// so a quick look elsewhere and back does not reload them.
    static let sideFeedLinger: TimeInterval = 60
    var sideFeedDisconnects: [FeedMode: DispatchWorkItem] = [:]

    /// The npub the currently-loaded feed belongs to. Used to know which key
    /// to snapshot against when the active account changes.
    var loadedSnapshotNpub: String = ""
    /// True while a background top-up is running against an already-rendered
    /// snapshot. Used by the UI to show a small inline "Syncing…" pill instead
    /// of the full-screen loading spinner.
    @Published var isSyncing: Bool = false
    /// Gate scroll-to-top: set by refresh/switchMode, not loadMore or topUp.
    var shouldScrollToTopOnLoad = false

    // Batched note buffer — avoids per-event @Published mutations
    var noteBuffer: [FeedNote] = []
    var noteFlushTimer: Timer?

    // Batched profile fetching — avoids per-pubkey WebSocket creation
    private var profileFetchQueue = Set<String>()
    private var profileFlushTimer: Timer?

    // Batched note fetching (e.g. for parent events in threads)
    var fetchingNoteIds = Set<String>()
    var fetchingNoteTimestamps: [String: Date] = [:] // Tracks when each fetch was started for retry
    var noteFetchQueue  = Set<String>()
    var noteFetchTimer: Timer?
    /// Where an e-tag says the referenced event lives (the NIP-10 relay hint).
    /// A root by someone outside your relays is often only there.
    var noteRelayHints: [String: URL] = [:]
    /// Who wrote a referenced note, when the reference says: the e-tag's
    /// NIP-10 pubkey slot, or the reply's p-tag. Their NIP-65 write relays
    /// are where the note actually lives (outbox model).
    var noteAuthorHints: [String: String] = [:]
    /// Fetch passes each referenced id has had with no answer.
    var noteFetchPasses: [String: Int] = [:]
    /// Referenced notes no relay returned after every pass. Thread cards show
    /// "unavailable" for these instead of loading forever.
    @Published var unavailableNoteIds = Set<String>()

    /// Asked on the second pass, for references neither your relays nor the
    /// author's carry. Picked by measurement, not reputation: on 2026-10-01
    /// the old set (damus, primal, nos.lol) left 59% of Following-tab thread
    /// roots unavailable — nos.lol refused connections and damus answered no
    /// REQ — and these found two thirds of what was left (19% remained).
    /// Re-measure with `.scratch/roots/probe5.py` in the Buzz nest before
    /// changing the list. offchain.pub was first until it began refusing
    /// connections (2026-10-12).
    static let fallbackNoteRelays = [
        "wss://nostr.wine",
        "wss://nostr.oxtr.dev",
        "wss://nostr.land",
        "wss://relay.nostrplebs.com",
        "wss://relay.snort.social",
        "wss://relay.primal.net",
        "wss://relay.damus.io",
    ]

    // Profile saving
    private var profileSaveTimer: Timer?

    // Periodic disk-snapshot persistence (crash safety; see init)
    private var snapshotPersistTimer: Timer?
    private var snapshotDirty = false

    private var configCancellables = Set<AnyCancellable>()

    // MARK: - Local Relay Injection

    /// WebSocket clients for injecting external events into the local relay.
    /// One for outbox (owner/whitelisted events), one for inbox (external events).
    var outboxInjectionClient: WebSocketClient?
    var inboxInjectionClient: WebSocketClient?
    /// Pending messages queued while injection clients are still connecting.
    var pendingOutboxMessages: [String] = []
    var pendingInboxMessages: [String] = []
    /// Tracks injected event IDs to prevent feedback loops.
    var injectedEventIds = Set<String>()
    let maxInjectedIds = 10_000
    /// True while FeedService is actively injecting events (used by NetworkSyncService to avoid overlap).
    @Published var isInjecting: Bool = false
    /// Throttles the `.feedInjectionComplete` notification.
    var lastInjectionNotification: Date = .distantPast

    /// The cached feed has been restored from disk for the current account.
    var didRestoreCachedFeed = false
    /// The one-time cold-start load has been kicked off for this launch.
    var didStartInitialLoad = false

    private init() {
        // FeedService no longer manages profiles; NostrService does.
        loadedSnapshotNpub = currentSnapshotKey()
        loadInteractionState(forKey: loadedSnapshotNpub)
        FollowingBackupService.shared.loadSnapshots(forAccountKey: loadedSnapshotNpub)

        // Put the cached feed on screen now, not in three seconds. Restoring a
        // disk snapshot is a local read with no relay in it, but it used to wait
        // behind `isReadyForConnections`, which fires three seconds after the
        // relay reports running — three seconds of launch with an empty feed.
        // The relay-dependent half still waits; see the readiness sink below.
        DispatchQueue.main.async { [weak self] in self?.prewarmFromCache() }

        // Listen to active account changes to reload the feed automatically.
        // We snapshot the previous account's state into memory and either
        // restore an existing snapshot (instant) or run a cold load.
        // activeAccountSwitches hops to main before delivering: @Published
        // emits from willSet, and read synchronously `config` would still
        // name the previous account, so that account's likes were shown
        // (and saved) under the new one.
        ConfigService.shared.activeAccountSwitches
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.handleAccountSwitch()
            }
            .store(in: &configCancellables)

        // Recompute filtered notes when display-relevant config changes.
        ConfigService.shared.$config
            .map { ($0.showReposts, $0.showReplies) }
            .removeDuplicates(by: ==)
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeFilteredNotes() }
            .store(in: &configCancellables)

        // Follows' relay lists arrive in batches after the feed is up; once
        // they settle, ask the new outbox relays (see `refreshOutboxPlan`).
        NostrService.shared.$outboxRelays
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileFeedSubscriptions() }
            .store(in: &configCancellables)

        // Blocking someone (here, or a mute list synced from another client)
        // must drop their posts now. Nothing listened for this before, so a
        // blocked author stayed on screen until some unrelated note arrived.
        NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeFilteredNotes() }
            .store(in: &configCancellables)

        // Drive cold-start convergence from relay readiness instead of relying on
        // FeedView's one-shot lifecycle observers (which silently no-op if their
        // guards miss the transition). When the local relay becomes ready, reconcile
        // the live subscriptions against the authoritative follow set. Stored in
        // `configCancellables` so it survives account switches (which wipe `cancellables`).
        RelayProcessManager.shared.$isReadyForConnections
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] ready in
                guard let self = self, ready, !self.isPaused else { return }
                if !self.didStartInitialLoad {
                    // Cold start: top-up on whatever `prewarmFromCache` restored,
                    // or cold-load when there was nothing to restore. Keyed off
                    // "have we started yet" rather than "is the feed empty",
                    // because the prewarm above may already have filled it — and
                    // a restored feed still needs its top-up.
                    self.startInitialLoad()
                } else {
                    // Already showing content: just reconcile the live subscriptions
                    // (add the local relay now that it's ready, repair drifted authors).
                    self.reconcileFeedSubscriptions()
                }
            }
            .store(in: &configCancellables)

        // Persist the disk snapshot periodically while the feed changes — not
        // just on background/terminate — so a crash or force-kill doesn't lose
        // the session and the next cold launch still restores instantly.
        $notes
            .dropFirst()
            .sink { [weak self] _ in self?.snapshotDirty = true }
            .store(in: &configCancellables)
        snapshotPersistTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.snapshotDirty, !self.isPaused,
                      self.feedMode != .popular, !self.notes.isEmpty else { return }
                self.snapshotDirty = false
                self.persistCurrentSnapshot()
            }
        }
    }

    // MARK: - Interaction State Persistence (per-account)

    var interactionSaveThrottle: Date = .distantPast

    var interactionSaveScheduled = false

    /// Whether the feed is currently paused (no active relay connections).
    var isPaused = false

    var pageLoadTimeout: Timer?

    // MARK: - Contact List (Kind 3)
    // Fetch the owner's follows from the local relay.
    // Falls back to a well-known public relay if not found locally.

    var contactLoadingTimeout: Timer?

    /// Follow / unfollow taps made before the follow list had loaded. They
    /// are applied, in order, as soon as it has — publishing a list before
    /// then could replace the real one on every relay.
    var pendingFollowActions: [(pubkey: String, follow: Bool, account: String)] = []

    // MARK: - Extended Network (Discovery Feed)
    
    var extendedNetworkTimeout: Timer?
    
    // MARK: - Feed Subscription (local + external in parallel)

    var feedLoadingTimeout: Timer?

/// Track per-relay connection failure counts for back-off
    var relayErrorCounts: [String: Int] = [:]

    // MARK: - Batched Note Flushing

    /// Maximum notes kept in memory. Older notes are dropped on flush. High bound so the
    /// user can scroll back through effectively their whole history (the List virtualizes
    /// rendering; this is only a ceiling against runaway memory).
    static let maxNotes = 10_000
    /// Maximum pending notes kept in memory. Older pending notes are dropped to
    /// prevent unbounded growth when the feed runs in the background.
    static let maxPendingNotes = 200

    // MARK: - Lookup sockets

    /// One socket per relay for missing-note lookups (thread roots, quotes),
    /// reused across flushes and closed once it has gone quiet.
    ///
    /// Each flush used to open a fresh socket to every relay it asked and drop
    /// it 8 s later. Scrolling a threaded feed flushes every few hundred ms,
    /// so on 2026-10-02 the iPhone opened ~500 WebSocket connections a minute
    /// to the same ~22 relays, 239 of them refused with HTTP 429, and the phone
    /// ran hot. Now the same relays see one connection each.
    struct LookupSocket {
        let client: WebSocketClient
        /// REQs waiting for the handshake to finish.
        var pending: [(req: String, subId: String)] = []
        var subscriptions = Set<AnyCancellable>()
        var idleClose: DispatchWorkItem?
    }

    var lookupSockets: [String: LookupSocket] = [:]
    /// Relays that refused or dropped a lookup socket, and when to try again.
    /// A 429 lands here, so a throttling relay is left alone instead of
    /// being redialled on the next flush.
    var lookupCooldownUntil: [String: Date] = [:]

    /// How long a lookup socket stays open after its last request. Longer than
    /// the 8 s a relay gets to answer, so a scroll keeps reusing it.
    static let lookupIdleSeconds: TimeInterval = 20
    static let lookupCooldownSeconds: TimeInterval = 120
    /// How long a lookup REQ stays open on the relay before we CLOSE it.
    static let lookupSubscriptionSeconds: TimeInterval = 8

    /// Authors whose relay list was already requested, so each is asked once.
    var relayListRequested = Set<String>()
}

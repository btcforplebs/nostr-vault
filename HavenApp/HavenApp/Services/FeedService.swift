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
    private var didAutoSwitchToCurated = false
    @Published var mediaFeedMode: MediaFeedMode = .following
    @Published var notes: [FeedNote] = []
    /// O(1) lookup index for notes by ID. Maintained alongside `notes` mutations.
    private(set) var noteIndex: [String: FeedNote] = [:]
    @Published var parentNotesCache: [String: FeedNote] = [:]
    /// Fires when referenced notes (thread parents, kind-6 originals, quoted
    /// notes) arrive and are cached. `parentNotesCache` alone is not a usable
    /// signal for the feed's row-data cache: rows are keyed by the *referencing*
    /// note's id, so a re-render changes nothing. See `ReferencedNoteSignal`.
    @Published private(set) var referencedNoteUpdates = ReferencedNoteSignal()
    private var pendingReferencedNoteIds: Set<String> = []
    private var referencedNoteFlushScheduled = false
    private var referencedNoteGeneration = 0

    /// Records that a referenced note arrived and schedules a coalesced flush,
    /// so a burst of parents landing together produces one row repair pass.
    /// Main-thread only (every call site is already on the main thread).
    private func noteReferencedNoteArrived(_ id: String) {
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
    private var extendedNetworkComputedAt: Date?
    private static let extendedNetworkCacheAge: TimeInterval = 3600 // 1 hour
    @Published var isLoadingContacts = false
    /// True once contact loading has completed at least once (success, empty, or timeout).
    /// Used to gate follow/unfollow so we don't publish before the kind-3 has had a chance to arrive,
    /// and — published, because the view needs it — to keep the Following feed from telling you that
    /// you follow nobody before it has ever asked. See `FollowingFeedState`.
    @Published private(set) var hasAttemptedContactLoad = false
    @Published var isLoadingExtendedNetwork = false
    @Published var isLoadingPopular = false
    @Published var popularFilter: PopularFilter = .all
    @Published var showPopularEngagement = false
    @Published var isLoadingFeed    = false
    /// Set by FeedView scroll tracking — true when user is scrolling down, used to collapse tab bar.
    @Published var feedScrollingDown = false
    @Published var connectionStatus = "Disconnected"

    /// Three-state connection indicator color
    var connectionDotColor: Color {
        switch connectionStatus {
        case "Live":
            return Color(red: 0.2, green: 0.8, blue: 0.6) // Green
        case "Disconnected", "No contacts found":
            return Color.red.opacity(0.8) // Red
        default:
            return Color(red: 1, green: 0.6, blue: 0.1) // Orange (loading/connecting)
        }
    }
    @Published var newNoteCount: Int = 0
    @Published var pendingNotes: [FeedNote] = []
    @Published var likedEventIds: Set<String> = []
    @Published var repostedEventIds: Set<String> = []
    @Published var zappedEventIds: [String: Int] = [:]
    /// Per-note engagement counts (replies, reactions, reposts) from relay data.
    @Published var noteStats: [String: NoteStats] = [:]

    // MARK: - Search
    @Published var isSearchActive: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [FeedNote] = []
    @Published var isSearching: Bool = false
    private var searchClient: WebSocketClient?
    private var searchCancellable: AnyCancellable?
    private var searchDebounceWork: DispatchWorkItem?

    // MARK: - Cached Filtered Notes (avoids O(n) filter on every SwiftUI render)
    @Published private(set) var filteredNotes: [FeedNote] = []
    @Published private(set) var filteredMediaNotes: [FeedNote] = []

    /// Set of note IDs where the parent event is the immediately next item in filteredNotes.
    /// Precomputed to avoid needing `Array(enumerated())` in the view's ForEach.
    private(set) var parentIsNextNote: Set<String> = []

    /// Rebuild the O(1) note lookup dictionary from the current `notes` array.
    private func rebuildNoteIndex() {
        noteIndex = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Recompute the cached filtered-notes arrays. Called after any mutation to
    /// `notes`, `feedMode`, or relevant config (showReposts / showReplies / blocked).
    func recomputeFilteredNotes() {
        rebuildNoteIndex()
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let throttled = ConfigService.shared.activeAccountThrottledHexPubkeys

        let newFiltered = FeedFilterEngine.filterFeedNotes(
            notes: notes,
            mode: feedMode,
            blocked: blocked,
            showReposts: ConfigService.shared.config.showReposts,
            showReplies: ConfigService.shared.config.showReplies,
            followedPubkeys: followedPubkeys,
            wotPubkeys: wotPubkeys,
            popularFilter: popularFilter,
            popularNoteScores: popularNoteScores,
            throttledPubkeys: throttled
        )

        // Only publish a change when the visible list actually differs.
        // Uses lazy zip to avoid allocating temporary [String] arrays.
        if newFiltered.count != filteredNotes.count ||
            !zip(newFiltered, filteredNotes).allSatisfy({ $0.id == $1.id }) {
            #if DEBUG
            if newFiltered.isEmpty && !notes.isEmpty {
                print("FeedService: [recompute] ⚠️ filtered→0 with notes=\(notes.count) mode=\(feedMode.rawValue) followedPubkeys=\(followedPubkeys.count)")
            }
            #endif
            filteredNotes = newFiltered
            parentIsNextNote = FeedFilterEngine.computeParentIsNext(filteredNotes: newFiltered)
        }

        let newMedia = FeedFilterEngine.filterMediaNotes(
            notes: notes,
            blocked: blocked,
            wotPubkeys: wotPubkeys,
            isGlobalMedia: feedMode == .media && mediaFeedMode == .global,
            throttledPubkeys: throttled
        )

        if newMedia.count != filteredMediaNotes.count ||
            !zip(newMedia, filteredMediaNotes).allSatisfy({ $0.id == $1.id }) {
            filteredMediaNotes = newMedia
        }
    }

    /// Cache of raw event JSON strings for NIP-18 repost embedding.
    /// Key: event ID, Value: complete stringified JSON of the event (includes sig).
    private(set) var rawEventCache: [String: String] = [:]
    /// FIFO insertion order for rawEventCache eviction (avoids O(n log n) sort).
    private var rawEventCacheOrder: [String] = []
    private static let maxRawEventCacheSize = 1000

    /// Insert a raw event JSON string into the cache (for own posts / rebroadcast).
    /// Every write to `rawEventCache` must go through here: a writer that
    /// bypasses `rawEventCacheOrder` lets the dict outgrow the order array,
    /// and eviction's removeFirst then traps (the recurring post-time crash).
    func cacheRawEvent(id: String, json: String) {
        if rawEventCache[id] == nil {
            rawEventCacheOrder.append(id)
        }
        rawEventCache[id] = json
        if rawEventCache.count > Self.maxRawEventCacheSize {
            // Clamp so a residual desync degrades to partial eviction
            // instead of trapping in removeFirst.
            let overflow = min(rawEventCache.count - Self.maxRawEventCacheSize,
                               rawEventCacheOrder.count)
            let keysToRemove = rawEventCacheOrder.prefix(overflow)
            for key in keysToRemove { rawEventCache.removeValue(forKey: key) }
            rawEventCacheOrder.removeFirst(overflow)
        }
        if rawEventCache.count > Self.maxRawEventCacheSize {
            // Still over cap: the dict holds keys the order array never
            // tracked. Drop untracked keys until back under the cap.
            let tracked = Set(rawEventCacheOrder)
            for key in rawEventCache.keys.filter({ !tracked.contains($0) }) {
                rawEventCache.removeValue(forKey: key)
                if rawEventCache.count <= Self.maxRawEventCacheSize { break }
            }
        }
    }

    // Preserve the original kind 3 content (relay hints) to avoid wiping it on follow/unfollow
    private var contactListContent: String = ""
    /// Authoritative full NIP-02 "p" tags from the latest kind-3 event.
    /// Each entry is ["p", hex-pubkey] or ["p", hex-pubkey, relay-url, petname].
    /// `followedPubkeys` is always derived from this array.
    private var contactListPTags: [[String]] = []
    /// Count of contacts returned by the last successful relay fetch.
    /// Used by the safety check in `publishContactList()`.
    private var lastFetchedContactCount: Int = 0
    /// `created_at` of the contact list we last published or committed locally.
    /// Guards the relay-fetch overwrite: a kind-3 from a relay is only accepted
    /// when its `created_at` is >= this value. Otherwise the relay copy is older
    /// than our latest local edit (e.g. a fresh follow whose publish hasn't
    /// propagated yet) and would silently drop follows — so we keep the local set
    /// and re-publish to heal the network. Persisted in the disk snapshot and the
    /// durable following backup so it survives relaunches and the 7-day snapshot TTL.
    private var ownContactListCreatedAt: Int64 = 0
    /// Account key `ownContactListCreatedAt` currently belongs to. When the active
    /// account changes the guard is reset so a previous account's (higher)
    /// timestamp never blocks the new account's relay copy.
    private var ownContactListAccountKey: String = ""

    /// Pubkeys that belong to the user's Web of Trust, loaded from the relay's
    /// cached WOT graph (`wot_cache.json`). Used to filter the GLOBAL feed and
    /// Media tab so only notes/media from WOT members are shown.
    @Published private(set) var wotPubkeys: Set<String> = []

    /// Popularity scores returned by the local DVM, keyed by note ID.
    /// Used to sort the Popular feed by engagement rank.
    private(set) var popularNoteScores: [String: Double] = [:]

    // One client per relay URL
    private var feedClients: [String: WebSocketClient] = [:]
    /// Relay keys whose messageSubject/connectionState sinks are currently live.
    /// A warm account switch calls cancellables.removeAll() but deliberately keeps
    /// feed clients connected (to avoid a full relay reconnect) — that call also
    /// silently orphans those clients' sinks, since removeAll() cancels every
    /// Combine subscription regardless of which relay it belonged to. Without this
    /// tracking, subscribeToAllRelays()'s "already connected, just resend the REQ"
    /// reuse branch has no way to know its sink is gone, so every incoming
    /// EVENT/EOSE on that socket is delivered to zero subscribers and silently
    /// dropped — the new account's feed looks stuck until the loading timeout.
    private var subscribedClientKeys = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private var seenIds = Set<String>()
    private static let maxSeenIds = 10_000

    /// Rebuild seenIds from currently retained notes once it outgrows the
    /// cap. The set otherwise grows for every note ever observed — a
    /// long-running session accumulates entries for notes evicted long ago.
    private func trimSeenIdsIfNeeded() {
        guard seenIds.count > Self.maxSeenIds else { return }
        var retained = Set(notes.map { $0.id })
        retained.formUnion(pendingNotes.map { $0.id })
        retained.formUnion(noteBuffer.map { $0.id })
        seenIds = retained
    }
    /// Timestamp (unix seconds) of the newest event successfully processed.
    /// Used on resume to narrow the relay filter to only the gap period.
    private var lastEventTimestamp: Int64 = 0
    /// `lastEventTimestamp` frozen at the start of the current subscription
    /// round so every relay in the round gets the same `since` window (see
    /// `feedSinceAndLimit`).
    private var subscriptionRoundSince: Int64 = 0
    private var newSinceLastView = Date()
    private var eoseCount = 0   // track when all relays return EOSE
    /// Relay keys that have received primary feed EOSE — triggers deferred auxiliary subscriptions.
    private var primaryEoseRelays = Set<String>()
    /// Maps primary feed subscription IDs to relay keys for EOSE → auxiliary dispatch.
    private var subIdToRelayKey: [String: String] = [:]

    /// The author set the live primary REQ was last sent with, per relay key.
    /// `nil`/absent for a relay key means no live primary subscription exists
    /// there (e.g. we skipped sending because the follow set was empty). This is
    /// the bookkeeping that makes `reconcileFeedSubscriptions()` a true reconcile:
    /// when the authoritative follow set changes we compare against this and only
    /// re-issue the REQ where it has actually drifted.
    private var subscribedAuthorsByRelay: [String: [String]] = [:]
    /// Re-entrancy guard — `reconcileFeedSubscriptions()` can be reached from a
    /// Combine sink, a Task continuation, and a view `onAppear` in the same runloop turn.
    private var isReconciling = false
    /// Prevents the cold-start empty-contacts background retry from looping.
    private var contactRetryScheduled = false

    // Background queue for JSON parsing — keeps the main thread free for UI
    private let processingQueue = DispatchQueue(label: "com.haven.feed-processing", qos: .userInitiated)

    // Thread-safe accumulator for background event parsing → main thread delivery.
    // All access is serialized on processingQueue.
    private let bgAccumulator = BackgroundAccumulator()

    var localRelayURL: URL? {
        // Only include the local relay when it is confirmed running.
        // During boot (WoT initialization, ~3 min) the HTTP server may be
        // listening but not fully ready, causing WebSocket failures.
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else { return nil }
        return URL(string: ConfigService.shared.config.nostrURL)
    }

    /// Local inbox relay — stores zaps, reactions, and mentions imported from seed relays.
    private var localInboxURL: URL? {
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else { return nil }
        return URL(string: ConfigService.shared.config.nostrURL + "/inbox")
    }

    /// Local feed-cache relay — follows' recent notes kept in sync by the
    /// embedded relay (negentropy against the feed relays). Serves the feed
    /// window from disk instantly on cold start and for pagination.
    private var localFeedURL: URL? {
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else { return nil }
        return URL(string: ConfigService.shared.config.nostrURL + "/feed")
    }

    /// Public relays used to supplement the local relay.
    /// Uses Blastr relays if configured, otherwise well-known defaults.
    private var externalRelayURLs: [URL] {
        let configured = ConfigService.shared.config.activeFeedRelays
        let strs = configured.isEmpty ? [
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configured
        return strs.compactMap { URL(string: $0) }
    }

    /// Used for de-duping relay URLs across the floor + outbox set.
    private static func normalizeRelayKey(_ urlStr: String) -> String? {
        FeedFilterEngine.normalizeRelayKey(urlStr)
    }

    /// Loads WOT pubkeys from the relay's cached `wot_cache.json` file.
    /// The relay computes this graph (owner -> follows -> follows-of-follows,
    /// filtered by minimum follower count) and persists it to disk.
    func loadWotPubkeys() {
        let cacheURL = ConfigService.shared.relayDataDir.appendingPathComponent("wot_cache.json")
        // nil = could not read the cache; keep whatever graph we already have.
        // Empty = read fine, but the graph names nobody but the owner (a new
        // account with no follows). That is no trust data, and the Global feed
        // treats an empty set as "show everything" rather than filtering the
        // whole world out — so it must be applied, not skipped, or a previous
        // account's graph would linger after a switch.
        guard let loaded = FeedFilterEngine.loadWotPubkeys(
            from: cacheURL,
            ownerHex: ConfigService.shared.activeAccountHexPubkey
        ) else {
            #if DEBUG
            print("FeedService: Could not read WOT cache from \(cacheURL.path)")
            #endif
            return
        }
        wotPubkeys = loaded
        #if DEBUG
        print("FeedService: Loaded \(wotPubkeys.count) usable WOT pubkeys from cache")
        #endif
        // Re-filter if we're currently in global mode
        if feedMode == .global || (feedMode == .media && mediaFeedMode == .global) {
            recomputeFilteredNotes()
        }
    }

    /// True when the Global feed has a trust graph to filter against. The
    /// relay writes `wot_cache.json` shortly after first launch, seeded from
    /// the starter pack for an owner who follows nobody — so on a brand-new
    /// install this is false for a few seconds and the feed legitimately has
    /// nothing to show yet.
    var curatedGraphReady: Bool { !wotPubkeys.isEmpty }

    /// Status text for a Global feed with no graph yet. Global fails closed, so
    /// without this the user would sit in front of an empty screen labelled
    /// "No notes found" and reasonably conclude the app is broken.
    private var curatedGraphPendingStatus: String { "Building your starter feed…" }

    private var curatedGraphPollAttempts = 0
    private var curatedGraphPollTimer: Timer?

    /// Re-read the trust graph until the relay has written one, then re-filter.
    /// Only runs while it would change what is on screen: a Global feed with an
    /// empty graph shows nothing at all.
    private func pollForCuratedGraph() {
        curatedGraphPollTimer?.invalidate()
        curatedGraphPollAttempts = 0
        guard isGlobalLikeMode, !curatedGraphReady else { return }

        connectionStatus = curatedGraphPendingStatus
        curatedGraphPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                self.curatedGraphPollAttempts += 1
                // ~2 minutes. If the graph has not appeared by then the relay
                // could not reach its seed relays, and retrying forever just
                // burns battery behind a screen that is already honest.
                guard self.isGlobalLikeMode, self.curatedGraphPollAttempts <= 40 else {
                    timer.invalidate()
                    self.curatedGraphPollTimer = nil
                    return
                }
                self.loadWotPubkeys()
                if self.curatedGraphReady {
                    timer.invalidate()
                    self.curatedGraphPollTimer = nil
                    self.recomputeFilteredNotes()
                    self.connectionStatus = self.filteredNotes.isEmpty ? "No notes found" : "Live"
                }
            }
        }
    }

    /// "No notes found" is a lie while the Global feed is waiting for its
    /// trust graph — there are plenty of notes, we just will not show notes we
    /// cannot vouch for.
    private func emptyFeedStatus() -> String {
        if !filteredNotes.isEmpty { return "Live" }
        if isGlobalLikeMode && !curatedGraphReady { return curatedGraphPendingStatus }
        return "No notes found"
    }

    private var isGlobalLikeMode: Bool {
        feedMode == .global || (feedMode == .media && mediaFeedMode == .global)
    }

/// In-memory per-account feed snapshots keyed by `activeAccountNpub`
    /// (empty string for the default/owner account). Captured before each
    /// account switch and restored when switching back, so re-switching is
    /// instant and the relay top-up runs as a background refresh.
    private var accountSnapshots: [String: AccountFeedSnapshot] = [:]
    /// The npub the currently-loaded feed belongs to. Used to know which key
    /// to snapshot against when the active account changes.
    private var loadedSnapshotNpub: String = ""
    /// True while a background top-up is running against an already-rendered
    /// snapshot. Used by the UI to show a small inline "Syncing…" pill instead
    /// of the full-screen loading spinner.
    @Published var isSyncing: Bool = false
    /// Gate scroll-to-top: set by refresh/switchMode, not loadMore or topUp.
    var shouldScrollToTopOnLoad = false

    // Batched note buffer — avoids per-event @Published mutations
    private var noteBuffer: [FeedNote] = []
    private var noteFlushTimer: Timer?

    // Batched profile fetching — avoids per-pubkey WebSocket creation
    private var profileFetchQueue = Set<String>()
    private var profileFlushTimer: Timer?

    // Batched note fetching (e.g. for parent events in threads)
    private var fetchingNoteIds = Set<String>()
    private var fetchingNoteTimestamps: [String: Date] = [:] // Tracks when each fetch was started for retry
    private var noteFetchQueue  = Set<String>()
    private var noteFetchTimer: Timer?

    // Profile saving
    private var profileSaveTimer: Timer?

    // Periodic disk-snapshot persistence (crash safety; see init)
    private var snapshotPersistTimer: Timer?
    private var snapshotDirty = false

    private var configCancellables = Set<AnyCancellable>()

    // MARK: - Local Relay Injection

    /// WebSocket clients for injecting external events into the local relay.
    /// One for outbox (owner/whitelisted events), one for inbox (external events).
    private var outboxInjectionClient: WebSocketClient?
    private var inboxInjectionClient: WebSocketClient?
    /// Pending messages queued while injection clients are still connecting.
    private var pendingOutboxMessages: [String] = []
    private var pendingInboxMessages: [String] = []
    /// Tracks injected event IDs to prevent feedback loops.
    private var injectedEventIds = Set<String>()
    private let maxInjectedIds = 10_000
    /// True while FeedService is actively injecting events (used by NetworkSyncService to avoid overlap).
    @Published var isInjecting: Bool = false
    /// Throttles the `.feedInjectionComplete` notification.
    private var lastInjectionNotification: Date = .distantPast

    /// The cached feed has been restored from disk for the current account.
    private var didRestoreCachedFeed = false
    /// The one-time cold-start load has been kicked off for this launch.
    private var didStartInitialLoad = false

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
        ConfigService.shared.$config
            .map { $0.activeAccountNpub }
            .removeDuplicates()
            .dropFirst()
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

    /// Stable in-memory cache key for the active account. Uses the configured
    /// `activeAccountNpub`, falling back to "owner" when the owner account is
    /// active so we never key on an empty string.
    func currentSnapshotKey() -> String {
        let npub = ConfigService.shared.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return npub.isEmpty ? "owner" : npub
    }

    /// Capture the current published feed state into `accountSnapshots[key]`.
    /// Bounded to ~200 notes so re-switching is cheap; full backfill comes
    /// from the top-up subscription that runs immediately after.
    private func captureSnapshot(forKey key: String) {
        guard !key.isEmpty else { return }
        let cappedNotes = Array(notes.prefix(200))
        let snap = AccountFeedSnapshot(
            notes: cappedNotes,
            parentNotesCache: parentNotesCache,
            followedPubkeys: followedPubkeys,
            extendedNetworkPubkeys: extendedNetworkPubkeys,
            seenIds: seenIds,
            noteStats: noteStats,
            likedEventIds: likedEventIds,
            zappedEventIds: zappedEventIds,
            contactListContent: contactListContent,
            contactListPTags: contactListPTags,
            lastFetchedContactCount: lastFetchedContactCount,
            hasAttemptedContactLoad: hasAttemptedContactLoad,
            capturedAt: Date(),
            lastEventTimestamp: lastEventTimestamp
        )
        accountSnapshots[key] = snap
        saveDiskSnapshot(forKey: key)
    }

    /// Restore a previously captured snapshot into published state. Returns
    /// true if a snapshot existed and was restored.
    @discardableResult
    private func restoreSnapshot(forKey key: String) -> Bool {
        guard let snap = accountSnapshots[key] else { return false }
        notes = snap.notes
        parentNotesCache = snap.parentNotesCache
        followedPubkeys = snap.followedPubkeys
        extendedNetworkPubkeys = snap.extendedNetworkPubkeys
        seenIds = snap.seenIds
        noteStats = snap.noteStats
        likedEventIds = snap.likedEventIds
        zappedEventIds = snap.zappedEventIds
        contactListContent = snap.contactListContent
        contactListPTags = snap.contactListPTags
        lastFetchedContactCount = snap.lastFetchedContactCount
        hasAttemptedContactLoad = snap.hasAttemptedContactLoad
        lastEventTimestamp = snap.lastEventTimestamp
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        recomputeFilteredNotes()
        return true
    }

    /// Reset just the in-memory published feed state (does not touch snapshots).
    /// Used before a cold load when no snapshot exists for the new account.
    private func clearInMemoryFeedState() {
        followedPubkeys.removeAll()
        extendedNetworkPubkeys.removeAll()
        notes.removeAll()
        parentNotesCache.removeAll()
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        fetchingNoteIds.removeAll()
        fetchingNoteTimestamps.removeAll()
        noteFetchQueue.removeAll()
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        noteStats.removeAll()
        popularNoteScores.removeAll()
        isLoadingPopular = false
        likedEventIds.removeAll()
        zappedEventIds.removeAll()
        contactListContent = ""
        contactListPTags.removeAll()
        lastFetchedContactCount = 0
        ownContactListCreatedAt = 0
        ownContactListAccountKey = ""
        hasAttemptedContactLoad = false
        lastEventTimestamp = 0
        recomputeFilteredNotes()
    }

    // MARK: - Disk Snapshot Persistence

    private nonisolated static func diskSnapshotURL(forKey key: String) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        let safeKey = key.isEmpty ? "owner" : key.replacingOccurrences(of: "/", with: "_")
        return havenDir.appendingPathComponent("feed_snapshot_\(safeKey).json")
    }

    private func saveDiskSnapshot(forKey key: String) {
        let disk = DiskFeedSnapshot(
            notes: Array(notes.prefix(200)),
            followedPubkeys: followedPubkeys,
            extendedNetworkPubkeys: extendedNetworkPubkeys,
            noteStats: noteStats,
            contactListContent: contactListContent,
            contactListPTags: contactListPTags,
            lastFetchedContactCount: lastFetchedContactCount,
            capturedAt: Date(),
            lastEventTimestamp: lastEventTimestamp,
            ownContactListCreatedAt: ownContactListCreatedAt
        )
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(disk) {
                try? data.write(to: Self.diskSnapshotURL(forKey: key))
            }
        }
    }

    private func loadDiskSnapshot(forKey key: String) -> DiskFeedSnapshot? {
        let url = Self.diskSnapshotURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(DiskFeedSnapshot.self, from: data) else {
            return nil
        }
        // Expire stale snapshots.
        if snap.capturedAt.timeIntervalSinceNow < -DiskFeedSnapshot.maxAge { return nil }
        return snap
    }

    private func diskSnapshotExists(forKey key: String) -> Bool {
        let url = Self.diskSnapshotURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Quick check: if file exists and isn't expired, we have a snapshot.
        // Don't decode the entire snapshot here — just check modification date.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return modDate.timeIntervalSinceNow >= -DiskFeedSnapshot.maxAge
    }

    /// Apply an on-disk snapshot for `key` into the published feed state.
    /// Mirrors the in-memory `restoreSnapshot` but sources from disk. Returns
    /// true when a (non-stale) snapshot existed and was applied. Does NOT start
    /// any relay traffic — the caller decides whether to top up or cold-load.
    @discardableResult
    private func applyDiskSnapshot(forKey key: String) -> Bool {
        guard let diskSnap = loadDiskSnapshot(forKey: key) else { return false }
        notes = diskSnap.notes
        followedPubkeys = diskSnap.followedPubkeys
        extendedNetworkPubkeys = diskSnap.extendedNetworkPubkeys
        if !diskSnap.extendedNetworkPubkeys.isEmpty {
            extendedNetworkComputedAt = diskSnap.capturedAt
        }
        noteStats = diskSnap.noteStats
        contactListContent = diskSnap.contactListContent
        contactListPTags = diskSnap.contactListPTags
        lastFetchedContactCount = diskSnap.lastFetchedContactCount
        ownContactListCreatedAt = diskSnap.ownContactListCreatedAt ?? 0
        ownContactListAccountKey = key
        seenIds = Set(diskSnap.notes.map { $0.id })
        lastEventTimestamp = diskSnap.lastEventTimestamp
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        loadInteractionState(forKey: key)
        recomputeFilteredNotes()
        return true
    }

    /// Cold-launch restore. When the feed is empty (fresh process) and a
    /// non-stale disk snapshot exists for the active account, restore it so the
    /// user sees their previous feed instantly. Returns true when restored — the
    /// caller should then run `topUpFromRelays()` to stream newer notes on top
    /// without a full reload. Returns false on first-ever launch (no snapshot),
    /// where the caller should fall back to `refresh()`.
    @discardableResult
    private func restoreFromDiskIfAvailable() -> Bool {
        guard notes.isEmpty else { return false }
        let key = currentSnapshotKey()
        loadedSnapshotNpub = key
        return applyDiskSnapshot(forKey: key)
    }

    /// Cold-launch entry point used by FeedView when the feed first appears with
    /// no notes. Restores the cached feed instantly when a disk snapshot exists,
    /// then streams newer notes on top via `topUpFromRelays()` (preserves scroll
    /// position and shows the inline "Syncing…" pill). Falls back to a full cold
    /// `refresh()` on first-ever launch or when no snapshot is available.
    func startInitialLoad() {
        didStartInitialLoad = true
        if feedMode == .popular {
            // Popular feed is ephemeral — never restored from a snapshot.
            refresh()
            return
        }
        if didRestoreCachedFeed || restoreFromDiskIfAvailable() {
            didRestoreCachedFeed = true
            topUpFromRelays()
        } else {
            refresh()
        }
    }

    /// Restore the cached feed at launch, before the relay is ready.
    ///
    /// Everything here is a local read — a disk snapshot, or the follow set from
    /// the following backup. None of it needs a relay, and holding it back until
    /// `isReadyForConnections` (three seconds after the relay reports running) is
    /// what made every launch flash an empty Following feed with a Refresh
    /// button. Subscribing is still the readiness sink's job.
    func prewarmFromCache() {
        guard !didRestoreCachedFeed, !didStartInitialLoad, !isPaused, feedMode != .popular else { return }

        if restoreFromDiskIfAvailable() {
            didRestoreCachedFeed = true
            return
        }

        // No cached notes, but a known follow set still turns the launch screen
        // from an accusation into a feed that is merely still filling.
        guard followedPubkeys.isEmpty,
              let backup = FollowingBackupService.shared.snapshots.last,
              !backup.pubkeys.isEmpty else { return }
        contactListPTags = backup.pTags
        followedPubkeys = backup.pubkeys
        contactListContent = backup.contactListContent
        lastFetchedContactCount = backup.pubkeys.count
    }

    /// Persist the current feed to disk so the next cold launch can restore it
    /// instantly (see `restoreFromDiskIfAvailable`). Call from app background /
    /// terminate hooks while notes are still in memory. No-op when the feed is
    /// empty. The actual encode + write runs off the main thread.
    func persistCurrentSnapshot() {
        guard !notes.isEmpty else { return }
        let key = loadedSnapshotNpub.isEmpty ? currentSnapshotKey() : loadedSnapshotNpub
        saveDiskSnapshot(forKey: key)
    }

    /// Snapshot the old account, restore (or cold-load) the new account, then
    /// kick off a relay top-up against the now-current state.
    private func handleAccountSwitch() {
        let previousKey = loadedSnapshotNpub
        let newKey = currentSnapshotKey()
        guard previousKey != newKey else { return }

        // 1. Stash the just-rendered state under the previous npub.
        captureSnapshot(forKey: previousKey)

        // 2. Only disconnect feed clients if we need a full refresh (no snapshot available).
        // This prevents unnecessary relay disconnections when switching between accounts
        // that have cached state. We'll disconnect later if needed during refresh().
        let hasSnapshot = accountSnapshots[newKey] != nil || diskSnapshotExists(forKey: newKey)
        if !hasSnapshot {
            // No snapshot — will need fresh data, so disconnect now.
            disconnectFeedClients()
        }
        // NOTE: Global services (profile + Kind 10002 fetches) keep their clients
        // running across account switches by design.

        // 3. Cancel in-flight loading flags + timers so the new flow isn't blocked.
        isLoadingContacts = false
        isLoadingExtendedNetwork = false
        extendedNetworkComputedAt = nil
        isLoadingFeed = false
        isSyncing = false
        contactLoadingTimeout?.invalidate()
        feedLoadingTimeout?.invalidate()
        extendedNetworkTimeout?.invalidate()
        cancellables.removeAll()
        // A warm account switch keeps feed clients connected (no disconnect), so
        // clear the previous account's author-set bookkeeping explicitly here —
        // otherwise a reconcile could see a "matching" stale set and skip the
        // resubscribe the new account needs.
        subscribedAuthorsByRelay.removeAll()
        // The removeAll() above just orphaned every surviving feed client's sink
        // (see subscribedClientKeys) — clear so subscribeToAllRelays() knows to
        // re-establish them instead of silently dropping this account's events.
        subscribedClientKeys.removeAll()
        contactRetryScheduled = false

        // 4. Either restore an in-memory snapshot OR cold-load.
        //    Wrapped in withAnimation so SwiftUI cross-fades the content
        //    transition instead of hard-cutting between accounts.
        var restored = false
        didStartInitialLoad = true
        didRestoreCachedFeed = false
        withAnimation(Motion.fade) {
            loadedSnapshotNpub = newKey
            restored = restoreSnapshot(forKey: newKey)
            if !restored {
                // No in-memory snapshot — fall back to the on-disk snapshot
                // (faster than a full cold load).
                restored = applyDiskSnapshot(forKey: newKey)
            }
            if !restored {
                // No cached feed — load persisted interaction state for this
                // account from disk so likes/zaps appear correctly even on first
                // visit after launch.
                clearInMemoryFeedState()
                loadInteractionState(forKey: newKey)
            }
            newNoteCount = 0
            newSinceLastView = Date()
            didRestoreCachedFeed = restored
        }

        // 5. Kick off relay traffic.
        if feedMode == .popular {
            // Popular feed is ephemeral — always re-fetch on account switch.
            loadPopularFeed()
        } else if restored {
            // Block follow/unfollow until the relay re-fetch completes,
            // so we don't publish the stale snapshot contact list.
            isLoadingContacts = true
            // Background top-up: subscribe to relays but keep the cached feed
            // visible. The inline syncing pill replaces the full-screen spinner.
            topUpFromRelays()
        } else if feedMode == .global || (feedMode == .media && mediaFeedMode == .global) {
            shouldScrollToTopOnLoad = true
            loadWotPubkeys()
            subscribeToAllRelays()
        } else {
            // Attempt to seed the follow set from FollowingBackupService's
            // persisted snapshots before falling back to a full cold load.
            // This turns most "cold" loads into warm loads — the feed subscribes
            // to relays immediately with the seed pubkeys and refreshes the
            // contact list in the background, just like topUpFromRelays().
            let backupService = FollowingBackupService.shared
            backupService.loadSnapshots(forAccountKey: newKey)

            if let latest = backupService.snapshots.last, !latest.pubkeys.isEmpty {
                contactListPTags = latest.pTags
                followedPubkeys = latest.pubkeys
                contactListContent = latest.contactListContent
                lastFetchedContactCount = latest.pubkeys.count
                isLoadingContacts = true

                if feedMode == .discovery {
                    // Discovery needs extended network before subscribing.
                    // Compute it from the seed contacts, then subscribe.
                    // Refresh the authoritative contact list in parallel.
                    isSyncing = true
                    loadExtendedNetwork { [weak self] in
                        self?.subscribeToAllRelays()
                    }
                    loadContactList { [weak self] in
                        self?.isSyncing = false
                    }
                } else {
                    topUpFromRelays()
                }
            } else {
                // No backup available — true cold start.
                refresh()
            }
        }
    }

    // MARK: - Interaction State Persistence (per-account)

    private var interactionSaveThrottle: Date = .distantPast

    /// Load engagement state (likes / zaps) for the given account snapshot key.
    /// Delegates to EngagementTracker for the actual disk I/O and migration logic.
    private func loadInteractionState(forKey key: String) {
        let result = EngagementTracker.loadInteractionState(forKey: key)
        self.likedEventIds = result.likedEventIds
        self.zappedEventIds = result.zappedEventIds
        #if DEBUG
        print("FeedService: Loaded \(result.likedEventIds.count) likes, \(result.zappedEventIds.count) zaps for account \(key.prefix(8))")
        #endif
    }

    func saveInteractionState() {
        // Throttle saves to at most once per 2 seconds
        let now = Date()
        guard now.timeIntervalSince(interactionSaveThrottle) > 2.0 else { return }
        interactionSaveThrottle = now
        EngagementTracker.saveInteractionState(
            likedEventIds: likedEventIds,
            zappedEventIds: zappedEventIds,
            forKey: loadedSnapshotNpub
        )
    }

    // MARK: - Public API

    func refresh() {
        guard !isLoadingContacts, !isPaused else { return }

        // Ask the embedded relay to catch up its inbox/outbox from external
        // relays too, so a feed pull-to-refresh also freshens the Relay tab,
        // DMs, and notifications. Non-blocking, coalesced, no-op-safe when the
        // relay isn't running.
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            RequestRelaySyncC()
        }

        if feedMode == .popular {
            loadPopularFeed()
            return
        }

        #if DEBUG
        print("FeedService: [refresh] start — followedPubkeys=\(followedPubkeys.count) notes=\(notes.count) filtered=\(filteredNotes.count)")
        #endif

        disconnectFeedClients()
        shouldScrollToTopOnLoad = true
        newNoteCount = 0
        newSinceLastView = Date()
        lastEventTimestamp = 0

        loadContactList { [weak self] in
            guard let self = self else { return }

            // Route a genuinely new Nostr user — no follows AND no local
            // following backup to seed from — to the curated Global feed.
            // Returning users whose contact fetch was merely slow/empty were
            // already seeded from backup by handleContactLoadResolved()
            // (seed-and-stay), so their followedPubkeys is non-empty here and
            // they stay on Following.
            //
            // This used to send them to Popular, which ranks raw engagement
            // from open relays: measured on the shipped seed relays, two thirds
            // of that traffic was one spam campaign, and it was the first thing
            // a new user ever saw. Global is now filtered by a trust graph the
            // relay seeds from the starter pack, and it fails closed while that
            // graph is still being built. Popular remains available as an
            // explicit choice in the feed menu.
            //
            // Nothing here publishes a contact list — the user's follows stay
            // empty until they choose to follow someone.
            let hasBackup = !(FollowingBackupService.shared.snapshots.last?.pubkeys.isEmpty ?? true)
            if self.followedPubkeys.isEmpty && self.isFollowSetMode && !hasBackup {
                self.didAutoSwitchToCurated = true
                self.feedMode = .global
                self.loadWotPubkeys()
                self.recomputeFilteredNotes()
                self.pollForCuratedGraph()
                self.subscribeToAllRelays()
                return
            }

            if self.feedMode == .discovery {
                self.loadExtendedNetwork { [weak self] in
                    self?.subscribeToAllRelays()
                }
            } else {
                self.subscribeToAllRelays()
            }
        }
    }

    // MARK: - Popular Feed (Local DVM)

    /// Query the local Go DVM for popular notes. The Go backend fetches
    /// engagement data (reactions, reposts, zaps) from seed relays, scores
    /// notes by popularity, and returns the top results.
    private func loadPopularFeed() {
        guard !isLoadingPopular else { return }
        isLoadingPopular = true
        isLoadingFeed = true
        shouldScrollToTopOnLoad = true
        connectionStatus = "Discovering popular notes..."
        notes.removeAll()
        popularNoteScores.removeAll()
        recomputeFilteredNotes()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let resultPtr = ComputePopularNotesC() else {
                DispatchQueue.main.async {
                    self?.isLoadingPopular = false
                    self?.isLoadingFeed = false
                    self?.connectionStatus = "No popular notes found"
                }
                return
            }
            let jsonString = String(cString: resultPtr)

            // Check for error response
            if let errorData = jsonString.data(using: .utf8),
               let errorObj = try? JSONSerialization.jsonObject(with: errorData) as? [String: String],
               let errorMsg = errorObj["error"] {
                DispatchQueue.main.async {
                    self?.isLoadingPopular = false
                    self?.isLoadingFeed = false
                    self?.connectionStatus = "Error: \(errorMsg)"
                }
                return
            }

            // Parse popular notes
            guard let data = jsonString.data(using: .utf8),
                  let popularNotes = try? JSONDecoder().decode([PopularNoteResult].self, from: data) else {
                DispatchQueue.main.async {
                    self?.isLoadingPopular = false
                    self?.isLoadingFeed = false
                    self?.connectionStatus = "Failed to parse results"
                }
                return
            }

            // Convert to FeedNote and build score map
            var feedNotes: [FeedNote] = []
            var scores: [String: Double] = [:]
            for pn in popularNotes {
                let note = FeedNote(
                    id: pn.id,
                    pubkey: pn.pubkey,
                    content: pn.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(pn.created_at)),
                    tags: pn.tags,
                    kind: pn.kind,
                    repostedBy: nil
                )
                feedNotes.append(note)
                scores[pn.id] = pn.score
            }

            DispatchQueue.main.async {
                guard let self = self, self.feedMode == .popular else { return }
                self.notes = feedNotes
                self.popularNoteScores = scores
                self.isLoadingPopular = false
                self.isLoadingFeed = false
                self.connectionStatus = feedNotes.isEmpty ? "No popular notes found" : "Live"
                self.recomputeFilteredNotes()
            }
        }
    }


    func switchMode(_ mode: FeedMode) {
        guard mode != feedMode else { return }
        if feedMode == .recipes && mode != .recipes {
            RecipeFeedService.shared.disconnect()
        }
        if feedMode == .live && mode != .live {
            LiveFeedService.shared.disconnect()
        }
        shouldScrollToTopOnLoad = true
        feedMode = mode
        notes.removeAll()
        parentNotesCache.removeAll()
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        fetchingNoteIds.removeAll()
        fetchingNoteTimestamps.removeAll()
        noteFetchQueue.removeAll()
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        noteStats.removeAll()
        popularNoteScores.removeAll()
        newNoteCount = 0
        newSinceLastView = Date()
        lastEventTimestamp = 0
        isSyncing = false
        recomputeFilteredNotes()
        // Disconnect feed clients before re-subscribing.
        disconnectFeedClients()
        cancellables.removeAll()

        // Reset global mode flag when switching away from global
        let isGlobal = mode == .global || (mode == .media && mediaFeedMode == .global)
        processingQueue.async { [weak self] in
            self?.bgAccumulator.isGlobalMode = isGlobal
        }

        if mode == .live {
            // Same reasoning as Recipes: LiveFeedService owns this one.
            LiveFeedService.shared.loadIfNeeded()
        } else if mode == .recipes {
            // Recipes are served by RecipeFeedService against external relays —
            // the note pipeline has nothing to subscribe to here, and starting
            // it would open follow-set subscriptions nothing will read.
            RecipeFeedService.shared.loadIfNeeded()
        } else if mode == .popular {
            loadPopularFeed()
        } else if isGlobal {
            // Global mode doesn't need contacts — subscribe directly
            loadWotPubkeys()
            pollForCuratedGraph()
            subscribeToAllRelays()
        } else {
            refresh()
        }
    }

    /// Discard the cached snapshot for the current account and run a full
    /// cold reload. Use sparingly — the normal account-switch path already
    /// restores instantly from the in-memory snapshot.
    func forceReload() {
        accountSnapshots.removeValue(forKey: loadedSnapshotNpub)
        clearInMemoryFeedState()
        shouldScrollToTopOnLoad = true
        newNoteCount = 0
        newSinceLastView = Date()
        isLoadingContacts = false
        isLoadingFeed = false
        isLoadingExtendedNetwork = false
        isSyncing = false
        contactLoadingTimeout?.invalidate()
        feedLoadingTimeout?.invalidate()
        extendedNetworkTimeout?.invalidate()
        disconnectFeedClients()
        cancellables.removeAll()

        if feedMode == .popular {
            loadPopularFeed()
        } else if feedMode == .global || (feedMode == .media && mediaFeedMode == .global) {
            loadWotPubkeys()
            subscribeToAllRelays()
        } else {
            refresh()
        }
    }

    /// Close only the feed-level WebSocket connections. The
    /// `NostrService.clients` pool is left alone so profile and Kind-10002
    /// lookups carry over across account switches.
    private func disconnectFeedClients() {
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()
        // No live subscriptions remain — drop the author-set bookkeeping so a
        // later reconcile doesn't think a relay is still subscribed.
        subscribedAuthorsByRelay.removeAll()
        subscribedClientKeys.removeAll()
        contactRetryScheduled = false
    }

    /// Whether the feed is currently paused (no active relay connections).
    private(set) var isPaused = false

    /// Disconnect feed relay clients and stop timers to reduce background
    /// resource usage. Call `resumeFeed()` to reconnect when the feed is
    /// visible again. Notes already in memory are preserved.
    func pauseFeed() {
        guard !isPaused else { return }
        isPaused = true
        disconnectFeedClients()
        disconnectInjectionClients()
        cancellables.removeAll()
        noteFlushTimer?.invalidate()
        noteFlushTimer = nil
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        feedLoadingTimeout?.invalidate()
        feedLoadingTimeout = nil
        isLoadingFeed = false
        isSyncing = false
        #if DEBUG
        print("FeedService: paused — relay clients disconnected")
        #endif
    }

    /// Reconnect to relays after a `pauseFeed()`. Only subscribes if we
    /// already have contacts loaded so we don't kick off a full cold start.
    func resumeFeed() {
        guard isPaused else { return }
        isPaused = false
        #if DEBUG
        print("FeedService: resuming — reconnecting relay clients")
        #endif
        if feedMode == .popular {
            // Popular feed doesn't use relay subscriptions — re-fetch if stale
            if notes.isEmpty { loadPopularFeed() }
        } else {
            // Route through the idempotent reconciler so resume reconnects the
            // right relay set and (re)subscribes with the current follow set —
            // and self-heals contacts if the follow set is somehow empty.
            reconcileFeedSubscriptions()
        }
    }

    // MARK: - Subscription Reconciliation

    /// True for feed modes whose primary subscription filters by an author set
    /// (Following / Media-Following / Discovery). Global, Popular and the inbox
    /// sub do not, so their subscriptions never drift on the follow set.
    private var isAuthorFilteredMode: Bool {
        switch feedMode {
        case .following, .discovery, .articles: return true
        case .media: return mediaFeedMode == .following
        case .global, .popular, .recipes, .live: return false
        }
    }

    /// Kinds the primary feed subscription asks for. Articles is a long-form
    /// feed, so narrowing the REQ stops a page of results from being almost
    /// entirely kind-1 notes the mode is about to discard.
    private var primaryFeedKinds: [Int] {
        feedMode == .articles ? [30023] : [1, 6, 30023]
    }

    /// True for the modes whose primary subscription is `authors: followedPubkeys`.
    /// Articles is Following restricted to kind 30023, so it shares every
    /// follow-set guard: the empty-follow-set short circuit, pagination, and the
    /// dead-`authors:[]` REQ guard.
    var isFollowSetMode: Bool {
        feedMode == .following || feedMode == .articles
    }

    /// The authoritative author set the current mode's primary subscription should
    /// carry. Empty means "no valid primary sub" for author-filtered modes.
    private func desiredPrimaryAuthorsForMode() -> [String] {
        switch feedMode {
        case .following, .articles: return followedPubkeys
        case .media: return mediaFeedMode == .following ? followedPubkeys : []
        case .discovery: return extendedNetworkPubkeys
        case .global, .popular, .recipes, .live: return []
        }
    }

    /// Desired authors for a specific relay key. Returns `nil` for relays that
    /// carry no author filter (the local inbox queries by `#p`; global/popular
    /// have no authors), so the drift check skips them.
    private func desiredPrimaryAuthors(forRelayKey key: String) -> [String]? {
        if key == localInboxURL?.absoluteString { return nil }
        return isAuthorFilteredMode ? desiredPrimaryAuthorsForMode() : nil
    }

    /// Make the live relay subscriptions match the current authoritative inputs
    /// (relayReady, feedMode, follow set, isPaused). Idempotent and safe to call
    /// from anywhere any number of times — never tears down the rendered feed,
    /// only connects missing relays and re-sends REQs whose author set has drifted.
    func reconcileFeedSubscriptions() {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        guard !isPaused else { return }
        guard feedMode != .popular else { return }   // popular has no relay subs

        // Author-filtered mode with no follows yet → no valid primary sub. Don't
        // send a dead authors:[] REQ; instead self-heal by (re)fetching contacts
        // if the relay is ready and we're not already loading. When follows land,
        // the contact-load completion calls back into reconcile.
        if isAuthorFilteredMode && desiredPrimaryAuthorsForMode().isEmpty {
            if RelayProcessManager.shared.isRunning,
               !RelayProcessManager.shared.isBooting,
               !isLoadingContacts, !isSyncing {
                loadContactList { [weak self] in self?.reconcileFeedSubscriptions() }
            }
            return
        }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty { return }

        ensureRelaySetConnected()
        resubscribePrimaryIfNeeded()
    }

    /// Connect the relays that should be part of the current subscription but
    /// aren't yet (notably the local relay/inbox once boot completes). Existing
    /// connections are left untouched. Absorbs the old `addLocalRelayIfReady`.
    private func ensureRelaySetConnected() {
        if feedMode == .global || (feedMode == .media && mediaFeedMode == .global) {
            loadWotPubkeys()
        }

        var desiredURLs: [URL] = []
        if let local = localRelayURL { desiredURLs.append(local) }
        if let inbox = localInboxURL { desiredURLs.append(inbox) }
        if let feed = localFeedURL { desiredURLs.append(feed) }
        desiredURLs.append(contentsOf: externalRelayURLs)

        let missing = desiredURLs.filter { feedClients[$0.absoluteString] == nil }
        guard !missing.isEmpty else { return }

        let totalRelays = feedClients.count + missing.count
        #if DEBUG
        print("FeedService: reconcile connecting \(missing.count) missing relay(s) (total \(totalRelays))")
        #endif
        for url in missing {
            connectFeedRelay(url: url, totalRelays: totalRelays)
        }
    }

    /// Re-issue the primary REQ to any connected feed client whose live author set
    /// differs from the desired one. Reuses the same `subId` so the relay replaces
    /// the prior subscription rather than opening a duplicate stream. `.connecting`
    /// clients are handled by their own connect sink (which reads the live follow
    /// set). Does NOT touch `isLoadingFeed`/`eoseCount` — a background resubscribe
    /// must not re-show the full-screen spinner.
    private func resubscribePrimaryIfNeeded() {
        for (key, client) in feedClients {
            guard client.connectionState == .connected else { continue }
            // nil-author relays (inbox/global/popular) never drift on follows.
            guard let desired = desiredPrimaryAuthors(forRelayKey: key) else { continue }
            if let current = subscribedAuthorsByRelay[key], Set(current) == Set(desired) {
                continue   // already in sync
            }
            sendPrimaryFeedSubscription(client: client, label: key)
        }
    }

    /// Send a raw Nostr message through the already-connected local relay client.
    /// Returns true if sent, false if no connected local client exists.
    func sendToLocalRelay(_ text: String) -> Bool {
        guard let key = localRelayURL?.absoluteString,
              let client = feedClients[key],
              client.connectionState == .connected else {
            return false
        }
        client.send(text: text)
        return true
    }

    /// Subscribe to raw messages on the local relay connection.
    /// Returns a cancellable, or nil if no local client is connected.
    func subscribeToLocalRelay(_ handler: @escaping (String) -> Void) -> AnyCancellable? {
        guard let key = localRelayURL?.absoluteString,
              let client = feedClients[key],
              client.connectionState == .connected else {
            return nil
        }
        return client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { msg in handler(msg) }
    }

    /// Background refresh against an already-rendered snapshot. Re-subscribes
    /// to relays so newer notes stream in on top of the cached feed, and
    /// kicks off a contact-list re-fetch in parallel so a stale follow set
    /// gets updated without blocking the visible feed.
    private func topUpFromRelays() {
        let isGlobalLike = feedMode == .global || (feedMode == .media && mediaFeedMode == .global)
        guard !followedPubkeys.isEmpty || isGlobalLike else {
            // Snapshot had no follows — fall back to the cold-start flow.
            refresh()
            return
        }

        isSyncing = true
        shouldScrollToTopOnLoad = false
        newSinceLastView = Date()

        // 1. Subscribe to relays immediately using the cached follow set.
        if isGlobalLike {
            loadWotPubkeys()
        }
        if isGlobalLike || !followedPubkeys.isEmpty {
            subscribeToAllRelays()
        }

        // 2. Re-fetch the contact list in the background. When it lands,
        // newly-followed authors are picked up by the running subscription on
        // the next refresh cycle (and `publishContactList` writes the diff).
        // We don't block on it.
        loadContactList { [weak self] in
            guard let self = self else { return }
            self.isSyncing = false
        }
    }

    func markViewed() {
        newNoteCount = 0
        newSinceLastView = Date()
    }

    func addNote(_ note: FeedNote) {
        if !notes.contains(where: { $0.id == note.id }) {
            notes.insert(note, at: 0)
            if notes.count > Self.maxNotes {
                notes.removeLast(notes.count - Self.maxNotes)
            }
            seenIds.insert(note.id)
            trimSeenIdsIfNeeded()
            recomputeFilteredNotes()
        }
    }

    func removeNote(id: String) {
        notes.removeAll { $0.id == id }
        pendingNotes.removeAll { $0.id == id }
        parentNotesCache.removeValue(forKey: id)
        recomputeFilteredNotes()
    }

    // MARK: - Search

    /// Debounced search: schedules a relay query after 400ms of inactivity.
    func searchDebounced(_ query: String) {
        searchDebounceWork?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.performSearch(query: trimmed)
        }
        searchDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Queries the local relay with the current feed mode's filter set and
    /// filters returned events client-side by content text matching.
    func performSearch(query: String) {
        guard let relayURL = localRelayURL else {
            // Fall back to in-memory search if relay unavailable
            searchResults = filteredNotes.filter {
                $0.content.localizedCaseInsensitiveContains(query)
            }
            isSearching = false
            return
        }

        // Cancel any previous search subscription
        searchCancellable?.cancel()
        searchClient?.disconnect()
        isSearching = true

        let client = WebSocketClient()
        client.isTemporary = true
        searchClient = client

        // Build filter matching current feed mode
        var filter: [String: Any] = [
            "kinds": [1, 6, 30023],
            "limit": 2000
        ]
        switch feedMode {
        case .following, .articles:
            if !followedPubkeys.isEmpty {
                filter["authors"] = followedPubkeys
            }
        case .discovery:
            if !extendedNetworkPubkeys.isEmpty {
                filter["authors"] = extendedNetworkPubkeys
            }
        case .global, .popular, .media, .recipes, .live:
            break // No author restriction — search everything
        }

        let subId = "search-\(UUID().uuidString.prefix(8))"
        var collected: [FeedNote] = []
        var seenSearchIds = Set<String>()
        let lowerQuery = query.lowercased()

        searchCancellable = client.messageSubject
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] (msg: String) in
                guard let data = msg.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = json[0] as? String else { return }

                if type == "EOSE" {
                    let results = collected.sorted {
                        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                        return $0.id > $1.id
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.searchResults = results
                        self.isSearching = false
                        self.searchClient?.disconnect()
                        self.searchClient = nil
                        self.searchCancellable = nil
                    }
                    return
                }

                guard type == "EVENT", json.count >= 3,
                      let ev = json[2] as? [String: Any],
                      let id        = ev["id"]         as? String,
                      let pubkey    = ev["pubkey"]      as? String,
                      let content   = ev["content"]     as? String,
                      let createdAt = ev["created_at"]  as? Int64,
                      let kind      = ev["kind"]        as? Int,
                      let tags      = ev["tags"]        as? [[String]]
                else { return }

                guard !seenSearchIds.contains(id) else { return }
                seenSearchIds.insert(id)

                let note = FeedNote(
                    id: id,
                    pubkey: pubkey,
                    content: content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                    tags: tags,
                    kind: kind,
                    repostedBy: kind == 6 ? pubkey : nil
                )

                // Client-side content filter
                if note.content.lowercased().contains(lowerQuery) {
                    collected.append(note)
                }
            }

        client.connect(url: relayURL)

        // Send REQ after a brief delay to ensure connection is established
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let req = ["REQ", subId, filter] as [Any]
            if let data = try? JSONSerialization.data(withJSONObject: req),
               let str = String(data: data, encoding: .utf8) {
                client.send(text: str)
            }
        }

        // Timeout: if EOSE never arrives, stop after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.isSearching else { return }
            let results = collected.sorted { $0.createdAt > $1.createdAt }
            self.searchResults = results
            self.isSearching = false
            self.searchClient?.disconnect()
            self.searchClient = nil
            self.searchCancellable = nil
        }
    }

    func clearSearch() {
        searchDebounceWork?.cancel()
        searchCancellable?.cancel()
        searchClient?.disconnect()
        searchClient = nil
        searchCancellable = nil
        searchQuery = ""
        searchResults = []
        isSearchActive = false
        isSearching = false
    }

    func applyPendingNotes() {
        guard !pendingNotes.isEmpty else { return }
        
        // Merge pending into active notes
        let newNotes = pendingNotes
        pendingNotes.removeAll()
        
        notes.append(contentsOf: newNotes)
        notes.sort { $0.createdAt > $1.createdAt }
        if notes.count > Self.maxNotes {
            notes.removeLast(notes.count - Self.maxNotes)
        }
        recomputeFilteredNotes()

        // Update new note count/tracking
        newSinceLastView = Date()
        newNoteCount = 0
    }

    /// Requests a fetch for a note that is missing from the local state.
    /// Used for resolving thread parents. Retries after 30s if the previous attempt failed silently.
    /// `force` bypasses that throttle, for a user-initiated Retry tap.
    func fetchMissingNote(id: String, force: Bool = false) {
        guard findNote(id: id) == nil else { return }
        if fetchingNoteIds.contains(id) {
            // Allow retry if the previous attempt was more than 30s ago
            if !force, let ts = fetchingNoteTimestamps[id], Date().timeIntervalSince(ts) < 30 {
                return
            }
            fetchingNoteIds.remove(id)
        }
        fetchingNoteIds.insert(id)
        fetchingNoteTimestamps[id] = Date()

        if id.hasPrefix(QuoteReference.coordinatePrefix) {
            fetchMissingNoteByNaddr(coordinate: id)
        } else {
            noteFetchQueue.insert(id)
            scheduleNoteFetchFlush()
        }
    }

    /// Fetches an addressable event by its naddr coordinate ("naddr:<kind>:<pubkey>:<d-tag>").
    private func fetchMissingNoteByNaddr(coordinate: String) {
        guard let (kind, pubkey, dTag) = QuoteReference.parseCoordinate(coordinate) else { return }

        let filter: [String: Any] = ["kinds": [kind], "authors": [pubkey], "#d": [dTag], "limit": 1]
        let subId = "naddr-\(UUID().uuidString.prefix(6))"
        let req = ["REQ", subId, filter] as [Any]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req),
              let reqStr = String(data: reqData, encoding: .utf8) else { return }

        var candidates: [URL] = []
        if let local = localRelayURL { candidates.append(local) }
        candidates.append(contentsOf: externalRelayURLs)

        for url in candidates {
            if let activeClient = feedClients[url.absoluteString],
               activeClient.connectionState == .connected {
                activeClient.send(text: reqStr)
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        activeClient.send(text: closeStr)
                    }
                }
                continue
            }

            let c = WebSocketClient()
            c.isTemporary = true
            c.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msg in self?.handleParentNoteFetch(msg) }
                .store(in: &cancellables)
            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        c.send(text: reqStr)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { c.disconnect() }
                    }
                }
                .store(in: &cancellables)
            c.connect(url: url)
        }
    }

    /// Looks up a note in the local parent notes cache or in the main feed list.
    /// Also handles naddr coordinate strings ("naddr:<kind>:<pubkey>:<d-tag>").
    func findNote(id: String) -> FeedNote? {
        if id.hasPrefix(QuoteReference.coordinatePrefix) {
            return findNoteByNaddrCoordinate(id)
        }
        if let cached = parentNotesCache[id] {
            return cached
        }
        return noteIndex[id]
    }

    /// Finds a note matching an naddr coordinate ("naddr:<kind>:<pubkey>:<d-tag>").
    private func findNoteByNaddrCoordinate(_ coordinate: String) -> FeedNote? {
        let matcher = QuoteReference.matcher(for: coordinate)
        let match: (FeedNote) -> Bool = { note in
            matcher.matches(id: note.id, kind: note.kind, pubkey: note.pubkey, tags: note.tags)
        }

        // Check parentNotesCache first
        if let cached = parentNotesCache.values.first(where: match) {
            return cached
        }
        return notes.first(where: match)
    }

    /// Load older notes (pagination) — fetches the page before the oldest note currently shown.
    func loadMore() {
        guard feedMode != .popular else { return } // Popular is a fixed ranked set
        guard !isLoadingFeed, let oldest = notes.last?.createdAt else { return }
        let until = Int64(oldest.timeIntervalSince1970) - 1
        if (isFollowSetMode || (feedMode == .media && mediaFeedMode == .following)) && followedPubkeys.isEmpty { return }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty { return }

        isLoadingFeed = true
        shouldScrollToTopOnLoad = false
        eoseCount = 0

        var allURLs: [URL] = []
        if let local = localRelayURL { allURLs.append(local) }
        if let inbox = localInboxURL { allURLs.append(inbox) }
        if let feed = localFeedURL { allURLs.append(feed) }
        allURLs.append(contentsOf: externalRelayURLs)

        let totalRelays = allURLs.count
        for url in allURLs {
            connectFeedRelayWithUntil(url: url, until: until, totalRelays: totalRelays)
        }
    }

    func disconnect() {
        feedLoadingTimeout?.invalidate()
        contactLoadingTimeout?.invalidate()
        disconnectFeedClients()
        cancellables.removeAll()
        connectionStatus = "Disconnected"
        isSyncing = false
    }

    // MARK: - Contact List (Kind 3)
    // Fetch the owner's follows from the local relay.
    // Falls back to a well-known public relay if not found locally.

    private var contactLoadingTimeout: Timer?

    private func loadContactList(completion: @escaping () -> Void) {
        let activeNpub = ConfigService.shared.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = activeNpub.isEmpty ? ConfigService.shared.config.ownerNpub : activeNpub
        guard !targetNpub.isEmpty,
              let ownerHex = Bech32.decode(targetNpub)?.hexString else {
            completion(); return
        }

        // Prime the local-edit guard from THIS account's durable backup before
        // fetching, so a relay copy older than our last known edit can't clobber it
        // — even on a cold start where the feed disk snapshot has expired (7-day TTL).
        // Reset across account switches so a previous account's timestamp can't
        // block the new account's relay copy.
        let snapshotKey = currentSnapshotKey()
        if ownContactListAccountKey != snapshotKey {
            ownContactListAccountKey = snapshotKey
            ownContactListCreatedAt = 0
        }
        ownContactListCreatedAt = max(
            ownContactListCreatedAt,
            FollowingBackupService.shared.latestContactListCreatedAt(forAccountKey: snapshotKey)
        )

        // Mark in-flight synchronously so a reconcile firing during the readiness
        // await doesn't kick off a duplicate fetch.
        isLoadingContacts = true
        connectionStatus = "Fetching contact list…"

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Give the local relay a chance to come up so it can serve the
            // authoritative kind-3 contact list. Bounded; warm starts return
            // immediately, and external relays are queried regardless of the result.
            _ = await RelayProcessManager.shared.ensureRelayReady(timeout: 8.0)
            // Bail if a newer load or an account switch superseded this one.
            guard self.isLoadingContacts,
                  ownerHex == ConfigService.shared.activeAccountHexPubkey else { return }
            self.beginContactFetch(ownerHex: ownerHex, completion: completion)
        }
    }

    private func beginContactFetch(ownerHex: String, completion: @escaping () -> Void) {
        // Safety timeout: if contact loading hasn't finished in 15 seconds, force completion
        contactLoadingTimeout?.invalidate()
        contactLoadingTimeout = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingContacts else { return }
                #if DEBUG
                print("FeedService: Contact loading timed out after 15s — forcing completion")
                #endif
                self.isLoadingContacts = false
                self.hasAttemptedContactLoad = true
                self.connectionStatus = self.followedPubkeys.isEmpty ? "Contact fetch timed out" : "Loaded \(self.followedPubkeys.count) contacts"
                self.handleContactLoadResolved()
                completion()
            }
        }

        // Connect to all relays in parallel — use the first one that returns a non-empty contact list.
        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        fetchContactListInParallel(from: candidates, ownerHex: ownerHex, completion: completion)
    }

    /// Called after a contact-load attempt resolves (success / empty / timeout).
    /// Seeds from the local following backup when the relay returned nothing
    /// (seed-and-stay, so the user sees their follows instead of an empty feed),
    /// then re-issues the primary REQ to already-connected relays whose author set
    /// has drifted. Fresh connects are handled by the caller's completion
    /// (e.g. refresh → subscribeToAllRelays); here we only repair live subs.
    private func handleContactLoadResolved() {
        if followedPubkeys.isEmpty {
            let backup = FollowingBackupService.shared
            backup.loadSnapshots(forAccountKey: currentSnapshotKey())
            if let latest = backup.snapshots.last, !latest.pubkeys.isEmpty {
                #if DEBUG
                print("FeedService: contact fetch empty — seeding \(latest.pubkeys.count) follows from backup, retry scheduled")
                #endif
                contactListPTags = latest.pTags
                followedPubkeys = latest.pubkeys
                contactListContent = latest.contactListContent
                lastFetchedContactCount = latest.pubkeys.count
                ownContactListCreatedAt = max(ownContactListCreatedAt, latest.contactListCreatedAt ?? 0)
                scheduleContactRetry()
            }
        }
        resubscribePrimaryIfNeeded()
    }

    /// Schedule a single background contact re-fetch ~5s out (e.g. after seeding
    /// from backup) so a slow/cold relay that wasn't ready yet gets another chance
    /// to deliver the authoritative kind-3. Guarded against looping.
    private func scheduleContactRetry() {
        guard !contactRetryScheduled else { return }
        contactRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.contactRetryScheduled = false
            guard !self.isLoadingContacts, !self.isPaused else { return }
            self.loadContactList { [weak self] in self?.resubscribePrimaryIfNeeded() }
        }
    }

    /// Opens a connection to every candidate relay simultaneously, collects the
    /// owner's kind-3 contact list from each, and commits the NEWEST one (by
    /// created_at) — kind-3 is a replaceable event, so the freshest version is
    /// authoritative, not whichever relay happens to answer first.
    private func fetchContactListInParallel(from relays: [URL], ownerHex: String, completion: @escaping () -> Void) {
        guard !relays.isEmpty else {
            contactLoadingTimeout?.invalidate()
            isLoadingContacts = false
            hasAttemptedContactLoad = true
            completion(); return
        }

        // Shared mutable state protected by main-thread dispatch.
        var completed = false
        var eoseCount = 0
        var clients: [WebSocketClient] = []
        // kind-3 is a REPLACEABLE event: keep the NEWEST version across relays, not
        // the first to arrive. Taking first-to-arrive let a stale relay copy
        // overwrite a fresh local edit — e.g. unfollow then refresh resurrected the
        // unfollowed user, and a fast relay serving an old/smaller list shrank the
        // feed. We collect candidates and commit the one with the max created_at.
        var best: (pTags: [[String]], content: String, createdAt: Int)?
        var graceWork: DispatchWorkItem?

        let finalize: () -> Void = { [weak self] in
            guard let self = self, !completed, self.isLoadingContacts else { return }
            // Discard responses that raced past an account switch.
            guard ownerHex == ConfigService.shared.activeAccountHexPubkey else {
                clients.forEach { $0.disconnect() }
                return
            }
            completed = true
            graceWork?.cancel()
            self.contactLoadingTimeout?.invalidate()
            clients.forEach { $0.disconnect() }

            if let best = best, Int64(best.createdAt) >= self.ownContactListCreatedAt {
                let parsed = ContactManager.parseContactList(
                    pTags: best.pTags,
                    ownerHex: ownerHex,
                    whitelistedNpubs: ConfigService.shared.config.whitelistedNpubs
                )
                #if DEBUG
                print("FeedService: [contact] commit newest created_at=\(best.createdAt) parsed=\(parsed.pubkeys.count) (was followedPubkeys=\(self.followedPubkeys.count))")
                #endif
                self.contactListPTags = parsed.pTags
                self.followedPubkeys = parsed.pubkeys
                self.contactListContent = best.content
                self.lastFetchedContactCount = parsed.relayPTagCount
                self.ownContactListCreatedAt = max(self.ownContactListCreatedAt, Int64(best.createdAt))
                self.connectionStatus = parsed.relayPTagCount == 0 ? "No contacts found" : "Loaded \(parsed.relayPTagCount) contacts"
                // Re-filter already-loaded notes against the committed follow set so the
                // visible feed reflects it immediately (don't wait for new notes to stream).
                self.recomputeFilteredNotes()
                FollowingBackupService.shared.maybeCreateSnapshot(
                    pubkeys: self.followedPubkeys,
                    pTags: parsed.pTags,
                    contactListContent: best.content,
                    contactListCreatedAt: Int64(best.createdAt),
                    forAccountKey: self.currentSnapshotKey()
                )
            } else if let best = best {
                // The newest kind-3 any relay returned is OLDER than the contact list
                // we last published/committed locally — our latest edit (e.g. a fresh
                // follow) hasn't propagated to these relays yet, so committing it would
                // silently drop follows. Keep the local set authoritative and re-publish
                // so the network catches up (self-heal).
                #if DEBUG
                print("FeedService: [contact] relay kind-3 stale (relay created_at=\(best.createdAt) < local \(self.ownContactListCreatedAt)) — keeping \(self.followedPubkeys.count) local follows and re-publishing")
                #endif
                self.connectionStatus = self.followedPubkeys.isEmpty ? "No contacts found" : "Loaded \(self.followedPubkeys.count) contacts"
                self.publishContactList()
            } else {
                // No kind-3 found anywhere — leave the existing follow set intact.
                #if DEBUG
                print("FeedService: [contact] no kind-3 found — followedPubkeys unchanged=\(self.followedPubkeys.count)")
                #endif
                self.connectionStatus = self.followedPubkeys.isEmpty ? "No contacts found" : "Loaded \(self.followedPubkeys.count) contacts"
            }

            self.isLoadingContacts = false
            self.hasAttemptedContactLoad = true
            self.handleContactLoadResolved()
            completion()
        }

        for url in relays {
            let c = WebSocketClient()
            c.isTemporary = true
            clients.append(c)

            c.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msg in
                    // self is only a liveness check here — bail once the
                    // service is gone rather than keep draining the socket.
                    guard !completed, self != nil else { return }
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let eventDict = json[2] as? [String: Any],
                       let kind = eventDict["kind"] as? Int, kind == 3,
                       let tags = eventDict["tags"] as? [[String]] {
                        let pTags = tags.filter { $0.count >= 2 && $0[0] == "p" }
                        let createdAt = (eventDict["created_at"] as? Int) ?? 0
                        #if DEBUG
                        print("FeedService: [contact] kind-3 from \(url.absoluteString) pTags=\(pTags.count) created_at=\(createdAt)")
                        #endif
                        guard !pTags.isEmpty else { return }
                        let content = eventDict["content"] as? String ?? ""
                        // Keep the newest version seen so far.
                        if best == nil || createdAt > best!.createdAt {
                            best = (pTags, content, createdAt)
                        }
                        // On the first usable kind-3, start a short grace window so a
                        // newer version from another relay can still win, then commit.
                        if graceWork == nil && !completed {
                            let work = DispatchWorkItem { finalize() }
                            graceWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
                        }
                    } else if type == "EOSE" {
                        eoseCount += 1
                        // Every relay has delivered its stored kind-3 (if any) before
                        // its EOSE — so once all have EOSE'd, `best` is the true newest.
                        if eoseCount >= relays.count && !completed {
                            finalize()
                        }
                    }
                }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard !completed, state == .connected else { return }
                    let filter: [String: Any] = ["kinds": [3], "authors": [ownerHex], "limit": 1]
                    let req = ["REQ", "cl-\(UUID().uuidString.prefix(4))", filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        c.send(text: str)
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }
    }

    // MARK: - Extended Network (Discovery Feed)
    
    private var extendedNetworkTimeout: Timer?
    
    private func loadExtendedNetwork(forceRefresh: Bool = false, completion: @escaping () -> Void) {
        guard !followedPubkeys.isEmpty else {
            completion()
            return
        }

        // Reuse cached result if recent enough
        if !forceRefresh,
           !extendedNetworkPubkeys.isEmpty,
           let computedAt = extendedNetworkComputedAt,
           Date().timeIntervalSince(computedAt) < Self.extendedNetworkCacheAge {
            #if DEBUG
            print("FeedService: Reusing cached extended network (\(extendedNetworkPubkeys.count) pubkeys, age \(Int(Date().timeIntervalSince(computedAt)))s)")
            #endif
            completion()
            return
        }

        isLoadingExtendedNetwork = true
        connectionStatus = "Analyzing network..."

        extendedNetworkTimeout?.invalidate()
        extendedNetworkTimeout = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingExtendedNetwork else { return }
                self.isLoadingExtendedNetwork = false
                completion()
            }
        }

        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        fetchExtendedNetworkInParallel(from: candidates, rootPubkeys: followedPubkeys) { [weak self] mutualCounts in
            guard let self = self else { return }
            self.extendedNetworkTimeout?.invalidate()
            self.extendedNetworkPubkeys = ContactManager.rankExtendedNetwork(mutualCounts: mutualCounts)
            self.extendedNetworkComputedAt = Date()
            self.isLoadingExtendedNetwork = false
            completion()
        }
    }

    /// Computes 2-hop mutual-follow counts rooted at `rootPubkeys` — fetches each
    /// root pubkey's own kind-3 follow list from `relays`, tallying how many roots
    /// follow each second-hop person (excluding the roots themselves).
    private func fetchExtendedNetworkInParallel(from relays: [URL], rootPubkeys: [String], completion: @escaping ([String: Int]) -> Void) {
        guard !relays.isEmpty, !rootPubkeys.isEmpty else {
            completion([:])
            return
        }

        var completed = false
        var eoseCount = 0
        var clients: [WebSocketClient] = []
        var mutualCounts: [String: Int] = [:]

        // Exclude the roots themselves
        let excludeSet = Set(rootPubkeys)

        let finish: () -> Void = {
            guard !completed else { return }
            completed = true
            clients.forEach { $0.disconnect() }
            completion(mutualCounts)
        }

        for url in relays {
            let c = WebSocketClient()
            c.isTemporary = true
            clients.append(c)

            c.messageSubject
                .receive(on: DispatchQueue.global(qos: .userInitiated))
                .sink { msg in
                    guard !completed else { return }
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let eventDict = json[2] as? [String: Any],
                       let kind = eventDict["kind"] as? Int, kind == 3,
                       let tags = eventDict["tags"] as? [[String]] {

                        let localCounts = ContactManager.countMutualFollows(
                            eventTags: tags,
                            excludeSet: excludeSet
                        )

                        DispatchQueue.main.async {
                            for (pk, count) in localCounts {
                                mutualCounts[pk, default: 0] += count
                            }
                        }

                    } else if type == "EOSE" {
                        DispatchQueue.main.async {
                            eoseCount += 1
                            // We wait for all EOSEs from active connections, but multiple REQs per connection might send multiple EOSEs.
                            // To be safe, wait for relays.count * chunks EOSEs, or rely on timeout. Let's just rely on timeout + simple EOSE count for now.
                            // Actually, let's just trigger finish if we reach some EOSE threshold.
                            if eoseCount >= relays.count {
                                finish()
                            }
                        }
                    }
                }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard !completed, state == .connected else { return }

                    var current = 0
                    var chunkIndex = 0
                    while current < rootPubkeys.count {
                        let end = min(current + 200, rootPubkeys.count)
                        let chunk = Array(rootPubkeys[current..<end])
                        let filter: [String: Any] = ["kinds": [3], "authors": chunk]
                        let req = ["REQ", "ext-\(chunkIndex)-\(UUID().uuidString.prefix(4))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            c.send(text: str)
                        }
                        current = end
                        chunkIndex += 1
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }

        // Without this, a single relay that never connects or never sends EOSE
        // (a slow/offline relay, or one that just doesn't implement it) stalls
        // this forever — finish() otherwise only fires once eoseCount reaches
        // relays.count, which a bad relay can never contribute to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { finish() }
    }


    // MARK: - Follow / Unfollow

    /// Backward-compatible typealias — error type now lives in ContactManager.
    typealias FollowActionError = ContactManager.FollowActionError

    @discardableResult
    func followUser(_ pubkey: String) -> Result<Void, FollowActionError> {
        switch ContactManager.prepareFollow(
            pubkey: pubkey,
            currentPTags: contactListPTags,
            currentPubkeys: followedPubkeys,
            hasAttemptedLoad: hasAttemptedContactLoad,
            isLoading: isLoadingContacts
        ) {
        case .failure(let err): return .failure(err)
        case .success(let result):
            contactListPTags = result.pTags
            followedPubkeys = result.pubkeys
            publishContactList()
            // Re-filter so already-loaded notes from the newly-followed author
            // surface immediately in the Following feed.
            recomputeFilteredNotes()
            // Re-issue the live primary REQ so the new follow's FUTURE notes stream
            // in without waiting for a full refresh.
            resubscribePrimaryIfNeeded()

            // Auto-switch back to Following now that the user has follows.
            if didAutoSwitchToCurated {
                didAutoSwitchToCurated = false
                switchMode(.following)
            }

            return .success(())
        }
    }

    @discardableResult
    func unfollowUser(_ pubkey: String) -> Result<Void, FollowActionError> {
        switch ContactManager.prepareUnfollow(
            pubkey: pubkey,
            activeAccountHex: ConfigService.shared.activeAccountHexPubkey,
            currentPTags: contactListPTags,
            currentPubkeys: followedPubkeys,
            hasAttemptedLoad: hasAttemptedContactLoad,
            isLoading: isLoadingContacts
        ) {
        case .failure(let err): return .failure(err)
        case .success(let result):
            contactListPTags = result.pTags
            followedPubkeys = result.pubkeys
            publishContactList()
            // Re-filter so the unfollowed author's notes disappear from the
            // Following feed immediately (the filter now excludes non-follows).
            recomputeFilteredNotes()
            // Re-issue the live primary REQ so the relay stops streaming the
            // unfollowed author's future notes.
            resubscribePrimaryIfNeeded()
            return .success(())
        }
    }

    private func publishContactList() {
        guard !contactListPTags.isEmpty else { return }
        if ContactManager.shouldBlockPublish(currentTagCount: contactListPTags.count, lastFetchedCount: lastFetchedContactCount) {
            #if DEBUG
            print("FeedService: BLOCKED contact list publish — \(contactListPTags.count) tags vs \(lastFetchedContactCount) fetched. Possible data loss.")
            #endif
            return
        }
        // Bump the local-edit guard synchronously to "now" so an immediate contact
        // refresh (firing before the async sign/post below completes) can't accept a
        // stale relay copy and drop the edit we're about to publish.
        ownContactListAccountKey = currentSnapshotKey()
        ownContactListCreatedAt = max(ownContactListCreatedAt, Int64(Date().timeIntervalSince1970))
        Task { [weak self] in
            guard let self = self else { return }
            guard let event = await NostrService.shared.signEventAsync(kind: 3, content: self.contactListContent, tags: self.contactListPTags) else { return }
            self.recordOwnContactList(event: event)
            NostrService.shared.postEvent(event)
        }
    }

    /// Records the timestamp + a durable backup of a contact list we just signed,
    /// so a later relay fetch returning an older copy can't clobber this edit.
    @MainActor
    private func recordOwnContactList(event: NostrEvent) {
        ownContactListCreatedAt = max(ownContactListCreatedAt, event.created_at)
        FollowingBackupService.shared.maybeCreateSnapshot(
            pubkeys: followedPubkeys,
            pTags: contactListPTags,
            contactListContent: contactListContent,
            contactListCreatedAt: event.created_at,
            forAccountKey: currentSnapshotKey()
        )
    }

    /// Restores the contact list from a backup, bypassing the shrinkage safety check.
    /// Used when the user explicitly chooses to restore from a historical Kind 3 event.
    func restoreContactList(pTags: [[String]], content: String) {
        guard !pTags.isEmpty else { return }
        self.contactListPTags = pTags
        self.followedPubkeys = pTags.compactMap { $0.count >= 2 ? $0[1] : nil }
        self.contactListContent = content
        self.lastFetchedContactCount = pTags.count
        Task { [weak self] in
            guard let self = self else { return }
            guard let event = await NostrService.shared.signEventAsync(kind: 3, content: self.contactListContent, tags: self.contactListPTags) else { return }
            self.recordOwnContactList(event: event)
            NostrService.shared.postEvent(event)
        }
    }

    // MARK: - Feed Subscription (local + external in parallel)

    private var feedLoadingTimeout: Timer?

    private func subscribeToAllRelays() {
        if (isFollowSetMode || (feedMode == .media && mediaFeedMode == .following)) && followedPubkeys.isEmpty {
            connectionStatus = "Follow someone on Nostr to see their posts here"
            return
        }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty {
            connectionStatus = "Follow more people to build your discovery network"
            return
        }

        isLoadingFeed = true
        eoseCount = 0
        primaryEoseRelays.removeAll()
        subIdToRelayKey.removeAll()
        relayErrorCounts.removeAll()
        connectionStatus = "Loading feed…"
        // Freeze the resume window for this round before any relay connects.
        subscriptionRoundSince = lastEventTimestamp

        // Use faster flush interval during initial load for snappier content display.
        // Global mode gets ultra-fast real-time flushing for streaming effect.
        let isGlobal = feedMode == .global || (feedMode == .media && mediaFeedMode == .global)
        processingQueue.async { [weak self] in
            self?.bgAccumulator.isInitialLoad = true
            self?.bgAccumulator.isGlobalMode = isGlobal
        }

        var allURLs: [URL] = []
        if let local = localRelayURL { allURLs.append(local) }
        if let inbox = localInboxURL { allURLs.append(inbox) }
        if let feed = localFeedURL { allURLs.append(feed) }
        allURLs.append(contentsOf: externalRelayURLs)

        let allKeys = Set(allURLs.map { $0.absoluteString })

        // Disconnect clients for relays no longer in the active set (e.g.
        // relay list changed).  Existing connected clients are kept alive —
        // callers that need a full teardown (account switch, mode switch,
        // forceReload) already call disconnectFeedClients() before this.
        for key in feedClients.keys where !allKeys.contains(key) {
            feedClients[key]?.disconnect()
            feedClients.removeValue(forKey: key)
        }

        let totalRelays = allURLs.count

        // Safety timeout: if feed loading hasn't finished in 20 seconds, flush what we have
        feedLoadingTimeout?.invalidate()
        feedLoadingTimeout = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingFeed else { return }
                #if DEBUG
                print("FeedService: Feed loading timed out after 20s — flushing \(self.noteBuffer.count) buffered notes (eoseCount=\(self.eoseCount)/\(totalRelays))")
                #endif
                self.flushNoteBuffer()
                self.isLoadingFeed = false
                self.isSyncing = false
                self.connectionStatus = self.emptyFeedStatus()
                self.processingQueue.async { [weak self] in
                    self?.bgAccumulator.isInitialLoad = false
                }
                // Trigger Mac relay sync after feed timeout too
                #if os(iOS)
                MacRelaySyncService.shared.syncIfConfigured()
                #endif
            }
        }

        // Connect local relay(s) immediately; stagger external connections
        // by 200ms each to avoid a TCP/TLS handshake storm on cellular.
        var externalQueue: [URL] = []
        for url in allURLs {
            let key = url.absoluteString
            if let existing = feedClients[key],
               existing.connectionState == .connected {
                // A warm account switch's cancellables.removeAll() can have orphaned
                // this client's sink (see subscribedClientKeys) without disconnecting
                // it — re-establish it before resending the REQ, or the response is
                // delivered to zero subscribers and silently dropped.
                if !subscribedClientKeys.contains(key) {
                    let isLocalRelay = url.host == "127.0.0.1" || url.host == "localhost"
                    subscribedClientKeys.insert(key)
                    existing.messageSubject
                        .receive(on: processingQueue)
                        .sink { [weak self] msg in
                            self?.handleFeedMsgBackground(msg, totalRelays: totalRelays)
                            if !isLocalRelay {
                                self?.handleExternalEventInjection(msg)
                            }
                        }
                        .store(in: &cancellables)
                }
                sendPrimaryFeedSubscription(client: existing, label: key)
            } else if url == localRelayURL || url == localInboxURL || url == localFeedURL {
                connectFeedRelay(url: url, totalRelays: totalRelays)
            } else {
                externalQueue.append(url)
            }
        }
        for (index, url) in externalQueue.enumerated() {
            let key = url.absoluteString
            if feedClients[key]?.connectionState == .connected || feedClients[key]?.connectionState == .connecting {
                continue
            }
            let delay = Double(index) * 0.2
            if delay == 0 {
                connectFeedRelay(url: url, totalRelays: totalRelays)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.isPaused else { return }
                    self.connectFeedRelay(url: url, totalRelays: totalRelays)
                }
            }
        }
    }

/// Track per-relay connection failure counts for back-off
    private var relayErrorCounts: [String: Int] = [:]

    private func connectFeedRelay(url: URL, totalRelays: Int) {
        let key = url.absoluteString
        if let existing = feedClients[key],
           existing.connectionState == .connected || existing.connectionState == .connecting {
            return
        }

        let c = WebSocketClient()
        feedClients[key] = c

        let isLocalRelay = url.host == "127.0.0.1" || url.host == "localhost"

        subscribedClientKeys.insert(key)
        c.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] msg in
                self?.handleFeedMsgBackground(msg, totalRelays: totalRelays)
                // Inject events from external relays into the local relay for persistence
                if !isLocalRelay {
                    self?.handleExternalEventInjection(msg)
                }
            }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .connected:
                    self.relayErrorCounts[key] = 0
                    self.sendPrimaryFeedSubscription(client: c, label: key)
                case .error:
                    let errorCount = (self.relayErrorCounts[key] ?? 0) + 1
                    self.relayErrorCounts[key] = errorCount

                    if errorCount >= 3 {
                        // After 3 failures, count this relay as done so loading can finish
                        #if DEBUG
                        print("FeedService: Relay \(key) failed \(errorCount) times — counting as EOSE")
                        #endif
                        self.eoseCount += 1
                        if self.eoseCount >= totalRelays {
                            self.feedLoadingTimeout?.invalidate()
                            self.flushNoteBuffer()
                            self.isLoadingFeed = false
                            self.isSyncing = false
                            self.connectionStatus = self.emptyFeedStatus()
                            self.processingQueue.async { [weak self] in
                                self?.bgAccumulator.isInitialLoad = false
                            }
                            #if os(iOS)
                            MacRelaySyncService.shared.syncIfConfigured()
                            #endif
                        }
                    } else {
                        // Retry after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard self?.feedClients[key] === c else { return }
                            self?.connectFeedRelay(url: url, totalRelays: totalRelays)
                        }
                    }
                default: break
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)
    }

    /// One-shot pagination client — opens, fetches until the given timestamp, then disconnects.
    private func connectFeedRelayWithUntil(url: URL, until: Int64, totalRelays: Int) {
        let key = "page-\(url.absoluteString)"
        let c = WebSocketClient()
        c.isTemporary = true
        feedClients[key] = c

        let isLocalRelay = url.host == "127.0.0.1" || url.host == "localhost"

        c.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] msg in
                self?.handleFeedMsgBackground(msg, totalRelays: totalRelays)
                if !isLocalRelay {
                    self?.handleExternalEventInjection(msg)
                }
            }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    self?.sendFeedSubscription(client: c, label: key, until: until)
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)
    }

    /// Shared "since" and filter computation for feed subscriptions.
    ///
    /// Uses `subscriptionRoundSince` — the value of `lastEventTimestamp` frozen
    /// at the start of the current subscription round — NOT the live value.
    /// Relays connect at different speeds (the local /feed cache answers in
    /// milliseconds, externals stagger in over seconds); with the live value, a
    /// fast relay's notes advance the timestamp before slow relays compute
    /// their REQ, so externals get asked only for the last ~60s and everything
    /// the fast relay didn't have silently disappears from the feed.
    private func feedSinceAndLimit(until: Int64? = nil) -> (since: Int64, limit: Int) {
        let isResume = subscriptionRoundSince > 0 && until == nil
        if isResume {
            return (subscriptionRoundSince - 60, feedMode == .media ? 500 : 500)
        } else {
            return (Int64(Date().timeIntervalSince1970) - (7 * 24 * 3600), feedMode == .media ? 300 : 500)
        }
    }

    private func feedSubId(for label: String) -> String {
        "feed-\(label.suffix(8).filter { $0.isLetter || $0.isNumber })"
    }

    /// Send only the primary feed filter (kinds 1, 6, 30023). Auxiliary subscriptions
    /// (mentions, reactions, zaps) are deferred until this relay's primary EOSE.
    private func sendPrimaryFeedSubscription(client: WebSocketClient, label: String) {
        let (since, limitVal) = feedSinceAndLimit()
        let isInbox = label == localInboxURL?.absoluteString
        let isFollowingLike = isFollowSetMode || (feedMode == .media && mediaFeedMode == .following)

        // GUARD: never send a dead `authors:[]` REQ for an author-filtered mode with
        // no authors yet — it matches zero notes and would silently stick. Record
        // that no live primary sub exists so `resubscribePrimaryIfNeeded()` re-sends
        // the moment the follow set / extended network arrives.
        if !isInbox && isFollowingLike && followedPubkeys.isEmpty {
            subscribedAuthorsByRelay[label] = nil
            return
        }
        if !isInbox && feedMode == .discovery && extendedNetworkPubkeys.isEmpty {
            subscribedAuthorsByRelay[label] = nil
            return
        }

        var filter: [String: Any] = [
            "kinds": primaryFeedKinds,
            "since": since,
            "limit": limitVal
        ]

        if isInbox {
            // The inbox stores events that TAG the owner (replies, mentions) — query
            // by #p rather than authors, since the authors are external users.
            let ownerHex = NostrService.shared.activeHexPubkey
            if !ownerHex.isEmpty {
                filter["#p"] = [ownerHex]
            }
        } else if isFollowingLike {
            filter["authors"] = followedPubkeys
        } else if feedMode == .discovery {
            filter["authors"] = extendedNetworkPubkeys
        }

        let subId = feedSubId(for: label)
        subIdToRelayKey[subId] = label

        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
            // Record the author set we just subscribed with so reconcile can detect
            // drift. Inbox/global/popular carry no author filter → record [].
            if isInbox {
                subscribedAuthorsByRelay[label] = []
            } else if isFollowingLike {
                subscribedAuthorsByRelay[label] = followedPubkeys
            } else if feedMode == .discovery {
                subscribedAuthorsByRelay[label] = extendedNetworkPubkeys
            } else {
                subscribedAuthorsByRelay[label] = []
            }
        }
    }

    /// Send auxiliary subscriptions (mentions, reactions, zaps) to a relay after
    /// its primary feed EOSE has arrived so feed content isn't bandwidth-starved.
    private func sendAuxiliarySubscriptions(client: WebSocketClient, label: String) {
        let isGlobal = feedMode == .global || (feedMode == .media && mediaFeedMode == .global)
        guard !isGlobal else { return }

        let ownerHex = NostrService.shared.activeHexPubkey
        guard !ownerHex.isEmpty else { return }

        let (since, _) = feedSinceAndLimit()
        let subId = feedSubId(for: label)

        // Mentions (#p) of the owner (from anyone)
        let mentionsFilter: [String: Any] = [
            "kinds": [1, 6, 30023],
            "since": since,
            "#p": [ownerHex],
            "limit": 50
        ]
        let mReq = ["REQ", "m-\(subId)", mentionsFilter] as [Any]
        if let mData = try? JSONSerialization.data(withJSONObject: mReq),
           let mStr = String(data: mData, encoding: .utf8) {
            client.send(text: mStr)
        }

        // Reactions from followed users
        let reactionsFilter: [String: Any] = [
            "kinds": [7],
            "authors": followedPubkeys,
            "since": since,
            "limit": 150
        ]
        let rxReq = ["REQ", "rx-\(subId)", reactionsFilter] as [Any]
        if let rxData = try? JSONSerialization.data(withJSONObject: rxReq),
           let rxStr = String(data: rxData, encoding: .utf8) {
            client.send(text: rxStr)
        }

        // Incoming zap receipts (kind 9735, #p = owner)
        let incomingZapsFilter: [String: Any] = [
            "kinds": [9735],
            "#p": [ownerHex],
            "since": since,
            "limit": 50
        ]
        let inZapsReq = ["REQ", "zaps-in-\(subId)", incomingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: inZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        // Outgoing zap requests (kind 9734, authored by owner)
        let outgoingZapsFilter: [String: Any] = [
            "kinds": [9734],
            "authors": [ownerHex],
            "since": since,
            "limit": 50
        ]
        let outZapsReq = ["REQ", "zaps-out-\(subId)", outgoingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: outZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    /// Combined subscription — sends primary + auxiliary at once. Used for
    /// pagination (connectFeedRelayWithUntil) where deferral isn't needed.
    private func sendFeedSubscription(client: WebSocketClient, label: String, until: Int64) {
        let (since, limitVal) = feedSinceAndLimit(until: until)
        var filter: [String: Any] = [
            "kinds": primaryFeedKinds,
            "since": since,
            "limit": limitVal
        ]
        if isFollowSetMode || (feedMode == .media && mediaFeedMode == .following) {
            filter["authors"] = followedPubkeys
        } else if feedMode == .discovery {
            filter["authors"] = extendedNetworkPubkeys
        }
        filter["until"] = until
        let subId = feedSubId(for: label)

        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        let isGlobal = feedMode == .global || (feedMode == .media && mediaFeedMode == .global)
        guard !isGlobal else { return }

        let ownerHex = NostrService.shared.activeHexPubkey
        guard !ownerHex.isEmpty else { return }

        var mentionsFilter = filter
        mentionsFilter["#p"] = [ownerHex]
        mentionsFilter["authors"] = nil
        mentionsFilter["limit"] = 50
        let mReq = ["REQ", "m-\(subId)", mentionsFilter] as [Any]
        if let mData = try? JSONSerialization.data(withJSONObject: mReq),
           let mStr = String(data: mData, encoding: .utf8) {
            client.send(text: mStr)
        }

        let reactionsFilter: [String: Any] = [
            "kinds": [7],
            "authors": followedPubkeys,
            "since": since,
            "limit": 150,
            "until": until
        ]
        let rxReq = ["REQ", "rx-\(subId)", reactionsFilter] as [Any]
        if let rxData = try? JSONSerialization.data(withJSONObject: rxReq),
           let rxStr = String(data: rxData, encoding: .utf8) {
            client.send(text: rxStr)
        }

        let incomingZapsFilter: [String: Any] = [
            "kinds": [9735],
            "#p": [ownerHex],
            "since": since,
            "limit": 50,
            "until": until
        ]
        let inZapsReq = ["REQ", "zaps-in-\(subId)", incomingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: inZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        let outgoingZapsFilter: [String: Any] = [
            "kinds": [9734],
            "authors": [ownerHex],
            "since": since,
            "limit": 50,
            "until": until
        ]
        let outZapsReq = ["REQ", "zaps-out-\(subId)", outgoingZapsFilter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: outZapsReq),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    /// Called on processingQueue — parses JSON off the main thread, accumulates in background buffers.
    /// A periodic flush delivers batched results to the main thread.
    private nonisolated func handleFeedMsgBackground(_ msg: String, totalRelays: Int) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EOSE" {
            // Only count EOSE from the primary feed subscription (prefix "feed-"),
            // not auxiliary subs (mentions "m-", reactions "rx-", zaps "zaps-")
            // which would inflate the count and end loading prematurely.
            let subId = json.count >= 2 ? json[1] as? String : nil
            let isPrimaryFeed = subId?.hasPrefix("feed-") == true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if isPrimaryFeed {
                    self.eoseCount += 1

                    // Dispatch deferred auxiliary subscriptions now that
                    // this relay's primary feed content has arrived.
                    if let subId = subId,
                       let relayKey = self.subIdToRelayKey[subId],
                       !self.primaryEoseRelays.contains(relayKey),
                       let client = self.feedClients[relayKey] {
                        self.primaryEoseRelays.insert(relayKey)
                        self.sendAuxiliarySubscriptions(client: client, label: relayKey)
                    }
                }
                if self.eoseCount >= totalRelays {
                    self.feedLoadingTimeout?.invalidate()
                    self.drainBackgroundBuffers()
                    self.flushNoteBuffer()
                    self.isLoadingFeed = false
                    self.isSyncing = false
                    self.connectionStatus = "Live"
                    self.processingQueue.async { [weak self] in
                        self?.bgAccumulator.isInitialLoad = false
                    }
                    // Trigger Mac relay sync after feed has finished initial load
                    #if os(iOS)
                    MacRelaySyncService.shared.syncIfConfigured()
                    #endif
                }
            }
            return
        }

        // Intercept parent-note fetch responses from reused active connections.
        // These come back on the permanent feed pipeline but belong to the fast-path
        // handler so they appear in the thread preview immediately, bypassing the
        // 0.8 s note-flush timer.
        if type == "EVENT", json.count >= 2,
           let subId = json[1] as? String, subId.hasPrefix("tfetch-") {
            DispatchQueue.main.async { [weak self] in
                self?.handleParentNoteFetch(msg)
            }
            return
        }

        guard type == "EVENT", json.count >= 3,
              let ev = json[2] as? [String: Any],
              let id        = ev["id"]         as? String,
              let pubkey    = ev["pubkey"]      as? String,
              let content   = ev["content"]     as? String,
              let createdAt = ev["created_at"]  as? Int64,
              let kind      = ev["kind"]        as? Int,
              let tags      = ev["tags"]        as? [[String]]
        else { return }

        // Ignore events with future timestamps (> 60 seconds in the future) to prevent feed corruption
        if Double(createdAt) > Date().timeIntervalSince1970 + 60 {
            return
        }

        // Handle Reactions (Kind 7) — track for self-like detection + per-note counting
        if kind == 7 {
            if let targetId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                let acc = self.bgAccumulator
                let reactorPubkey = pubkey
                let eventId = id
                processingQueue.async { [weak self] in
                    // Deduplicate reactions from multiple relays
                    guard !acc.seenEngagementIds.contains(eventId) else { return }
                    acc.seenEngagementIds.insert(eventId)
                    acc.reactionEvents.append((targetId: targetId, pubkey: reactorPubkey))
                    self?.scheduleBackgroundFlush()
                }
            }
            return
        }

        // Handle Zap Receipts (Kind 9735) and Zap Requests (Kind 9734)
        // Forward to NostrService so ViewerView can access them via nostrService.events
        if kind == 9735 || kind == 9734 {
            if let evData = try? JSONSerialization.data(withJSONObject: ev),
               let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                DispatchQueue.main.async {
                    if kind == 9735 {
                        guard let recipientPubkey = tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] else { return }
                        Task {
                            guard await ZapValidationService.isValidReceipt(pubkey: pubkey, recipientPubkey: recipientPubkey) else { return }
                            NostrService.shared.injectEvent(event)
                        }
                    } else {
                        NostrService.shared.injectEvent(event)
                    }
                }
            }
            return
        }

        // FeedNote.init handles kind 6 JSON embedding internally: it swaps to the inner
        // author/content/tags and sets repostedBy. Passing the raw event through is enough.
        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind,
            repostedBy: kind == 6 ? pubkey : nil
        )

        // Filter out obvious spam/noise from being processed
        if FeedNote.isNoiseOrSpam(content: note.content, tags: note.tags) {
            return
        }

        // NIP-18: Cache raw event JSON for repost embedding.
        // For kind 1/30023: serialize the full event dict (includes sig).
        // For kind 6 with embedded content: the content IS the inner event's JSON.
        var rawEntries: [(id: String, json: String)] = []
        if kind == 1 || kind == 30023 {
            if let data = try? JSONSerialization.data(withJSONObject: ev, options: []),
               let json = String(data: data, encoding: .utf8) {
                rawEntries.append((id: id, json: json))
            }
        }
        if kind == 6, !content.isEmpty,
           let innerData = content.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
           let innerId = inner["id"] as? String {
            rawEntries.append((id: innerId, json: content))
        }

        // Accumulate on processing queue — NO per-event main thread dispatch
        let acc = self.bgAccumulator
        processingQueue.async { [weak self] in
            acc.notes.append(note)
            acc.profiles.append(pubkey)
            acc.rawEventEntries.append(contentsOf: rawEntries)
            // After FeedNote.init swaps for kind 6 reposts, note.pubkey is the original author.
            // Fetch their profile too so the reposted card renders with the right name/avatar.
            if note.pubkey != pubkey { acc.profiles.append(note.pubkey) }

            // Track engagement: reposts (kind 6)
            if kind == 6 {
                if let targetId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                    acc.repostTargets.append(targetId)
                }
            }

            // Parents are prefetched in applySnapshot (proactive, so they arrive before
            // the child row appears). Repost/quoted fetches still happen on onAppear.
            self?.scheduleBackgroundFlush()
        }
    }

    /// Schedule a single coalesced flush of the background buffers → main thread.
    /// Must be called on processingQueue.
    private nonisolated func scheduleBackgroundFlush() {
        dispatchPrecondition(condition: .onQueue(processingQueue))
        let acc = bgAccumulator
        guard !acc.flushScheduled else { return }
        acc.flushScheduled = true
        processingQueue.asyncAfter(deadline: .now() + acc.effectiveFlushInterval) { [weak self] in
            self?.deliverBackgroundBatch()
        }
    }

    /// Take everything accumulated on the processing queue and deliver it to main in one dispatch.
    private nonisolated func deliverBackgroundBatch() {
        dispatchPrecondition(condition: .onQueue(processingQueue))
        let snap = bgAccumulator.drain()

        guard !snap.notes.isEmpty || !snap.reactionEvents.isEmpty || !snap.repostTargets.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.applySnapshot(snap)
        }
    }

    /// Force-drain background buffers synchronously (called on main before EOSE flush).
    private func drainBackgroundBuffers() {
        let acc = bgAccumulator
        var snap: BackgroundAccumulator.Snapshot!
        processingQueue.sync {
            snap = acc.drain()
        }
        applySnapshot(snap)
    }

    /// Apply a drained snapshot to main-actor state.
    private func applySnapshot(_ snap: BackgroundAccumulator.Snapshot) {
        var added = false
        var parentIdsToFetch: [String] = []
        for note in snap.notes {
            guard !seenIds.contains(note.id) else { continue }
            seenIds.insert(note.id)
            noteBuffer.append(note)
            added = true
            let ts = Int64(note.createdAt.timeIntervalSince1970)
            if ts > lastEventTimestamp {
                lastEventTimestamp = ts
            }
            // Prefetch parents proactively so they're cached before the row scrolls
            // into view — otherwise the child renders before the parent arrives.
            if let parentId = note.parentEventId {
                parentIdsToFetch.append(parentId)
            }
        }
        trimSeenIdsIfNeeded()

        for parentId in parentIdsToFetch {
            fetchMissingNote(id: parentId)
        }

        let uniquePubkeys = Set(snap.profiles).subtracting(Set(NostrService.shared.profiles.keys))
        if !uniquePubkeys.isEmpty {
            NostrService.shared.fetchMissingProfiles(for: Array(uniquePubkeys))
        }

        // Process reaction events: self-like detection + per-note counting
        let hasEngagement = !snap.reactionEvents.isEmpty || !snap.repostTargets.isEmpty
        if hasEngagement {
            let ownerHex = NostrService.shared.activeHexPubkey

            // Self-likes: reactions authored by the owner
            let selfLikes = EngagementTracker.detectSelfLikes(reactions: snap.reactionEvents, ownerHex: ownerHex)
            if !selfLikes.isEmpty {
                let before = likedEventIds.count
                likedEventIds.formUnion(selfLikes)
                if likedEventIds.count > before {
                    saveInteractionState()
                }
            }

            // Merge engagement counts (single dictionary assignment for one @Published update)
            noteStats = EngagementTracker.mergeEngagementCounts(
                reactions: snap.reactionEvents,
                repostTargets: snap.repostTargets,
                currentStats: noteStats
            )
        }

        // Merge raw event JSON entries into the cache for NIP-18 repost embedding.
        // Must go through cacheRawEvent so the FIFO order array stays in sync
        // (it also enforces the size cap).
        for entry in snap.rawEventEntries {
            cacheRawEvent(id: entry.id, json: entry.json)
        }

        if added {
            scheduleNoteFlush()
        }
    }

    // MARK: - Batched Note Flushing

    /// Maximum notes kept in memory. Older notes are dropped on flush. High bound so the
    /// user can scroll back through effectively their whole history (the List virtualizes
    /// rendering; this is only a ceiling against runaway memory).
    private static let maxNotes = 10_000
    /// Maximum pending notes kept in memory. Older pending notes are dropped to
    /// prevent unbounded growth when the feed runs in the background.
    private static let maxPendingNotes = 200

    private func scheduleNoteFlush() {
        guard noteFlushTimer == nil else { return }
        // Global feed uses ultra-fast flushing for real-time streaming feel
        let interval: TimeInterval = (feedMode == .global || (feedMode == .media && mediaFeedMode == .global)) ? 0.05 : 0.8
        noteFlushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushNoteBuffer()
            }
        }
    }

    private func flushNoteBuffer() {
        noteFlushTimer?.invalidate()
        noteFlushTimer = nil
        guard !noteBuffer.isEmpty else { return }

        let batch = noteBuffer
        noteBuffer.removeAll(keepingCapacity: true)

        // Prefetch media content types for the batch — moves HTTP HEAD detection
        // out of the rendering path so FeedMediaView has cached types when it renders.
        // Cap at 50 URLs per flush to avoid excessive HTTP HEAD requests in the background.
        let allMediaURLs = Array(batch.flatMap { $0.mediaURLs }.prefix(50))
        if !allMediaURLs.isEmpty {
            MediaTypeDetector.shared.prefetchContentTypes(for: allMediaURLs)
        }

        // During initial load, add everything at once then sort once.
        // Build the array locally to avoid multiple @Published mutations
        // (each triggers objectWillChange and a SwiftUI body re-evaluation).
        if notes.isEmpty || isLoadingFeed {
            var updated = notes
            updated.append(contentsOf: batch)
            updated.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }
            if updated.count > Self.maxNotes {
                updated.removeLast(updated.count - Self.maxNotes)
            }
            notes = updated  // single @Published assignment
            recomputeFilteredNotes()
            return
        }

        // Live updates: buffer new top-level notes to prevent feed jumping
        let newestDate = notes.first?.createdAt ?? Date.distantPast
        let driftThreshold = newestDate.addingTimeInterval(-60) // 60 seconds grace period for relay clock drift

        var toAdd: [FeedNote] = []
        var toPending: [FeedNote] = []

        for note in batch {
            if note.createdAt > driftThreshold && !note.isReply {
                // Always buffer new top-of-feed notes as pending to prevent
                // scroll disruption. FeedView auto-applies them when autoLoad is on.
                toPending.append(note)
            } else {
                toAdd.append(note)
            }
        }

        if !toAdd.isEmpty {
            // Build locally, assign once to minimize objectWillChange notifications
            var updated = notes
            updated.append(contentsOf: toAdd)
            updated.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }
            if updated.count > Self.maxNotes {
                updated.removeLast(updated.count - Self.maxNotes)
            }
            notes = updated
        }

        if !toPending.isEmpty {
            let updatedPending = pendingNotes + toPending
            let uniqueMap = Dictionary(updatedPending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var sorted = uniqueMap.values.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }
            // Drop oldest pending notes to prevent unbounded memory growth
            if sorted.count > Self.maxPendingNotes {
                sorted.removeLast(sorted.count - Self.maxPendingNotes)
            }
            pendingNotes = sorted
        }

        if !toAdd.isEmpty {
            recomputeFilteredNotes()
        }

        trimEngagementStateIfNeeded()
    }

    /// Trim noteStats to only contain entries for notes currently in memory.
    /// Called after notes are flushed to prevent unbounded growth of engagement data.
    private func trimEngagementStateIfNeeded() {
        guard noteStats.count > Self.maxNotes else { return }
        let activeIds = Set(notes.map { $0.id }).union(parentNotesCache.keys)
        noteStats = noteStats.filter { activeIds.contains($0.key) }
    }

    // MARK: - Note Fetching logic

    private func scheduleNoteFetchFlush() {
        guard noteFetchTimer == nil else { return }
        noteFetchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushNoteFetchRequests()
            }
        }
    }

    private func flushNoteFetchRequests() {
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        guard !noteFetchQueue.isEmpty else { return }

        let ids = Array(noteFetchQueue)
        noteFetchQueue.removeAll()

        // Fan out to local + all external relays — first response wins, later ones
        // are dropped by handleParentNoteFetch's findNote guard. Local-only was too
        // slow because replies often reference notes from people you don't follow,
        // which are not mirrored on the local relay.
        var candidates: [URL] = []
        if let local = localRelayURL {
            candidates.append(local)
        }
        candidates.append(contentsOf: externalRelayURLs)

        #if DEBUG
        print("FeedService: Fetching \(ids.count) missing notes for threading")
        #endif

        for url in candidates {
            let subId = "tfetch-\(UUID().uuidString.prefix(6))"
            let filter: [String: Any] = ["ids": ids]
            let req = ["REQ", subId, filter] as [Any]
            guard let reqData = try? JSONSerialization.data(withJSONObject: req),
                  let reqStr = String(data: reqData, encoding: .utf8) else { continue }

            // Fast path: reuse an already-connected feed client for this relay.
            // This avoids a full TCP + TLS + WebSocket handshake (typically 1-3 s)
            // and delivers the parent note in milliseconds instead.
            if let activeClient = feedClients[url.absoluteString],
               activeClient.connectionState == .connected {
                activeClient.send(text: reqStr)

                // Schedule CLOSE to release the subscription on the relay after results arrive.
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        activeClient.send(text: closeStr)
                    }
                }

                #if DEBUG
                print("FeedService: tfetch reusing active connection → \(url.host ?? url.absoluteString)")
                #endif
                continue
            }

            // Fallback: open a temporary connection when no active one is available.
            let c = WebSocketClient()
            c.isTemporary = true

            // Temporary connections don't go through handleFeedMsgBackground, so
            // subscribe the fast-path handler directly on the message subject.
            c.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msg in self?.handleParentNoteFetch(msg) }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        c.send(text: reqStr)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            c.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }
    }

    /// Fast-path handler for parent note fetches — inserts directly into notes on the main
    /// thread without going through the batch accumulator or flush timers.
    private func handleParentNoteFetch(_ msg: String) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String,
              type == "EVENT", json.count >= 3,
              let ev = json[2] as? [String: Any],
              let id        = ev["id"]        as? String,
              let pubkey    = ev["pubkey"]     as? String,
              let content   = ev["content"]    as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind      = ev["kind"]       as? Int,
              let tags      = ev["tags"]       as? [[String]]
        else { return }

        // Use findNote rather than seenIds: a note can be in seenIds but evicted from
        // notes[] by the 800-cap flush, in which case we still need it in parentNotesCache.
        guard findNote(id: id) == nil else { return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )

        guard !FeedNote.isNoiseOrSpam(content: note.content, tags: note.tags) else { return }

        // Cache raw event JSON for NIP-18 repost embedding
        if kind == 1 || kind == 30023 {
            if let evData = try? JSONSerialization.data(withJSONObject: ev, options: []),
               let evJSON = String(data: evData, encoding: .utf8) {
                cacheRawEvent(id: id, json: evJSON)
            }
        }

        fetchingNoteIds.remove(id)
        fetchingNoteTimestamps.removeValue(forKey: id)
        parentNotesCache[id] = note
        noteReferencedNoteArrived(id)
        if parentNotesCache.count > 500 {
            let referencedIds = Set(notes.compactMap { $0.parentEventId })
            parentNotesCache = parentNotesCache.filter { referencedIds.contains($0.key) }
        }
        NostrService.shared.fetchMissingProfiles(for: [pubkey])
    }

    // MARK: - Per-Note Stats Fetch (NoteDetailView)

    /// Fetches accurate repost / reaction / zap counts for a single note
    /// by querying all configured relays in parallel. Results are deduped by event
    /// ID so counts are never inflated when the same event arrives from multiple
    /// relays. Writes the final tally to `noteStats[noteId]` on the main thread.
    func fetchNoteStats(for noteId: String) {
        // Prefer local relay; only fall back to one external relay to cap data use.
        var allURLs: [URL] = []
        if let local = localRelayURL {
            allURLs.append(local)
        }
        if let inbox = localInboxURL {
            allURLs.append(inbox)
        }
        if allURLs.isEmpty, let first = externalRelayURLs.first {
            allURLs.append(first)
        }
        guard !allURLs.isEmpty else { return }

        // Shared mutable state — all mutations happen on the main thread via
        // DispatchQueue.main.async so no locks are needed.
        var seenEventIds = Set<String>()
        var reposts  = 0
        var reactions = 0
        var zaps     = 0
        var eoseReceived = 0
        // Each relay sends EOSE for each of the 3 subscriptions
        let expectedEOSE = allURLs.count * 3
        var finished = false
        var tempClients: [WebSocketClient] = []

        let finish: () -> Void = { [weak self] in
            guard let self = self, !finished else { return }
            finished = true
            tempClients.forEach { $0.disconnect() }
            var stats = self.noteStats[noteId] ?? NoteStats()
            stats.reposts   = reposts
            stats.reactions = reactions
            stats.zaps      = zaps
            self.noteStats[noteId] = stats
        }

        // Safety timeout: finalize after 8 seconds regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }

        let subPrefix = UUID().uuidString.prefix(6)

        for (i, url) in allURLs.enumerated() {
            let client = WebSocketClient()
            client.isTemporary = true
            tempClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    guard !finished,
                          let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EOSE" {
                        eoseReceived += 1
                        if eoseReceived >= expectedEOSE { finish() }
                        return
                    }

                    guard type == "EVENT", json.count >= 3,
                          let ev   = json[2] as? [String: Any],
                          let evId = ev["id"] as? String,
                          let kind = ev["kind"] as? Int,
                          !seenEventIds.contains(evId) else { return }

                    seenEventIds.insert(evId)

                    switch kind {
                    case 6:    reposts   += 1
                    case 7:    reactions += 1
                    case 9735: zaps      += 1
                    default:   break
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected, !finished else { return }
                    let p = "\(subPrefix)-\(i)"
                    let filters: [[String: Any]] = [
                        ["kinds": [6],    "#e": [noteId], "limit": 100],
                        ["kinds": [7],    "#e": [noteId], "limit": 100],
                        ["kinds": [9735], "#e": [noteId], "limit": 100],
                    ]
                    for (fi, filter) in filters.enumerated() {
                        let req = ["REQ", "\(p)-\(fi)", filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqStr  = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqStr)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    // MARK: - Local Relay Injection

    /// Injects an external event into the local relay. Safe to call from any
    /// context — hops to MainActor internally. Filters to feed-relevant kinds
    /// (1, 6, 7, 30023, 9735) and deduplicates via the shared injectedEventIds set.
    nonisolated func injectExternalEvent(_ eventDict: [String: Any], eventId: String) {
        guard let kind = eventDict["kind"] as? Int,
              [1, 6, 7, 30023, 9735].contains(kind) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.injectIntoLocalRelay(eventDict, eventId: eventId)
        }
    }

    /// Parses an external relay message and injects the event into the local relay.
    /// Called on `processingQueue` — must be thread-safe.
    private nonisolated func handleExternalEventInjection(_ msg: String) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 3,
              let type = json[0] as? String, type == "EVENT",
              let ev = json[2] as? [String: Any],
              let eventId = ev["id"] as? String else { return }

        // Only inject feed-relevant event kinds (notes, reactions, reposts, zaps)
        guard let kind = ev["kind"] as? Int,
              [1, 6, 7, 30023, 9735].contains(kind) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.injectIntoLocalRelay(ev, eventId: eventId)
        }
    }

    /// Writes an event to the local relay. Routes owner/whitelisted events to outbox,
    /// external events to /inbox (which has no blast hook, preventing feedback loops).
    private func injectIntoLocalRelay(_ eventDict: [String: Any], eventId: String) {
        // Dedup: skip events already injected this session
        guard !injectedEventIds.contains(eventId) else { return }
        injectedEventIds.insert(eventId)
        if injectedEventIds.count > maxInjectedIds {
            injectedEventIds.removeAll(keepingCapacity: true)
            injectedEventIds.insert(eventId)
        }

        let config = ConfigService.shared.config
        let ownerHex = Bech32.decode(config.ownerNpub)?.hexString ?? ""
        let whitelisted = ConfigService.shared.whitelistedHexPubkeys

        let pubkey = eventDict["pubkey"] as? String ?? ""
        let isTrackedAuthor = pubkey == ownerHex || whitelisted.contains(pubkey)

        let msg: [Any] = ["EVENT", eventDict]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        // Route to the appropriate injection client
        if isTrackedAuthor {
            sendToOutboxInjection(str)
        } else {
            sendToInboxInjection(str)
        }

        notifyInjectionComplete()
    }

    /// Sends a message to the outbox injection client, queuing if not yet connected.
    private func sendToOutboxInjection(_ str: String) {
        if let client = outboxInjectionClient, client.connectionState == .connected {
            client.send(text: str)
            return
        }

        pendingOutboxMessages.append(str)

        // Already connecting, just queue
        if outboxInjectionClient != nil { return }

        guard let url = URL(string: ConfigService.shared.config.nostrURL) else { return }

        let client = WebSocketClient()
        client.isTemporary = false
        outboxInjectionClient = client
        isInjecting = true

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, state == .connected else { return }
                for pending in self.pendingOutboxMessages {
                    client.send(text: pending)
                }
                self.pendingOutboxMessages.removeAll()
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    /// Sends a message to the inbox injection client, queuing if not yet connected.
    private func sendToInboxInjection(_ str: String) {
        if let client = inboxInjectionClient, client.connectionState == .connected {
            client.send(text: str)
            return
        }

        pendingInboxMessages.append(str)

        // Already connecting, just queue
        if inboxInjectionClient != nil { return }

        guard let url = URL(string: ConfigService.shared.config.nostrURL + "/inbox") else { return }

        let client = WebSocketClient()
        client.isTemporary = false
        inboxInjectionClient = client
        isInjecting = true

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, state == .connected else { return }
                for pending in self.pendingInboxMessages {
                    client.send(text: pending)
                }
                self.pendingInboxMessages.removeAll()
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    /// Disconnects injection clients (called from pauseFeed).
    private func disconnectInjectionClients() {
        outboxInjectionClient?.disconnect()
        outboxInjectionClient = nil
        inboxInjectionClient?.disconnect()
        inboxInjectionClient = nil
        pendingOutboxMessages.removeAll()
        pendingInboxMessages.removeAll()
        isInjecting = false
    }

    /// Posts `.feedInjectionComplete` at most once per 30 seconds.
    private func notifyInjectionComplete() {
        let now = Date()
        guard now.timeIntervalSince(lastInjectionNotification) > 30 else { return }
        lastInjectionNotification = now
        NotificationCenter.default.post(name: .feedInjectionComplete, object: nil)
    }
}

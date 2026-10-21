import Foundation
import Combine
import SwiftUI

@MainActor
class NostrService: ObservableObject {
    static let shared = NostrService()
    // These are no longer @Published to prevent background-thread notification crashes.
    // We notify manually on the main thread via the throttled subject.
    var events: [NostrEvent] = []
    var noteMedia: [MediaItem] = []

    /// Max events held in memory for the Viewer/Relay tab. Raised so the user can
    /// scroll back through (effectively) their whole history. The 10k ceiling was
    /// historically a jetsam risk because of full kind-30023 long-form bodies, so
    /// those are bounded separately by `maxLongFormEvents` below — the lightweight
    /// bulk (notes/reactions/zaps) can use the full ceiling without the memory blowup.
    static let maxEvents = 10_000
    /// Cap on retained full long-form (kind 30023) bodies — these are large, and were
    /// the main contributor to the ~310 MB resident set that made the app the #1 jetsam
    /// target. The newest this many are kept in full; older ones drop off the list.
    static let maxLongFormEvents = 500
    /// Cap on media items harvested from events for the gallery tab. Unlike `events`
    /// this list was never trimmed, so it grew for the process lifetime — and each
    /// item carries a copy of its source event's full tag list.
    static let maxNoteMedia = 4_000

    // Aggregated status
    @Published var connectionStatus: String = "Disconnected"
    @Published var connectionColor: String = "gray"
    @Published var isFetching: Bool = false

    /// Set by SceneDelegate when it handles foreground reconnection.
    /// ViewerView checks this to avoid redundant refreshAll() calls.
    var lastForegroundReconnectTime: Date?

    var seenEventIds = Set<String>()
    /// Guards `seenEventIds`, which is read/written from BOTH the background
    /// `processingQueue` (processMessage) and the main thread (postEvent,
    /// injectEvent, handleAccountSwitch). Without it the concurrent non-atomic
    /// Set mutations corrupt its storage → random EXC_BAD_ACCESS. Always go
    /// through markSeen/hasSeen/clearSeen; never touch `seenEventIds` directly.
    let seenLock = NSLock()
    var clients: [String: WebSocketClient] = [:]
    var activeSubscriptions: [String: String] = [:] // [RelayURL: SubID]
    var cancellables = Set<AnyCancellable>()
    /// Temporary WebSocketClient instances that aren't stored in `clients`.
    /// Held here to give them a predictable lifetime: they are removed
    /// when they disconnect, rather than relying on Combine sink captures.
    var temporaryClients: Set<WebSocketClient> = []
    private var configCancellable: AnyCancellable? // Stored separately so resetConnections() doesn't destroy it
    var statusDowngradeTask: Task<Void, Never>?
    let processingQueue = DispatchQueue(label: "com.haven.nostr-processing", qos: .userInitiated)

    // Relay List Metadata Cache (Kind 10002)
    @Published var relayLists: [String: [String]] = [:] // [Pubkey: [InboxRelayURLs]]
    @Published var outboxRelays: [String: [String]] = [:] // [Pubkey: [WriteRelayURLs]]
    /// created_at of the kind-10002 event currently reflected in relayLists/outboxRelays,
    /// per pubkey — guards against a late-arriving stale relay list (from a lagging relay)
    /// clobbering a fresher one, same failure mode as the kind-3 follow-list clobber bug.
    var relayListCreatedAt: [String: Int64] = [:]
    var relaysInFlight = Set<String>()

    // DM Relay List Cache (Kind 10050 - NIP-17)
    @Published var dmRelayLists: [String: [String]] = [:] // [Pubkey: [DMRelayURLs]]
    var dmRelaysInFlight = Set<String>()

    // BUD-03: User Server Lists (Kind 10063)
    @Published var serverLists: [String: [String]] = [:] // [Pubkey: [BlossomServerURLs]]

    // Batching updates to the UI
    let eventUpdateSubject = PassthroughSubject<Void, Never>()

    // Buffered event batching — avoids per-event main thread dispatch
    var eventBuffer: [(NostrEvent, [MediaItem])] = []
    let bufferLock = NSLock()
    var bufferFlushTimer: Timer?

    // Pagination tracking
    var activeSubscriptionCount = 0
    /// Safety net for `fetchNotes`: force-clears `isFetching` if subscription
    /// EOSEs never arrive (unreachable relay, or a socket torn down mid-fetch),
    /// so the Viewer/Relay "Loading notes…" overlay can never latch indefinitely.
    var fetchWatchdogTask: Task<Void, Never>?
    var profilesInFlight = Set<String>()
    var profileFetchQueue = Set<String>()
    var profileFlushCancellable: AnyCancellable?
    /// The UI is hidden (`enterBackground`): profiles queue up, and the fetch
    /// timer waits for `enterForeground` instead of starting on enqueue.
    var profileFetchPaused = false

    /// Pause the profile-fetch timer when the UI is hidden to avoid
    /// unnecessary network requests and CPU usage in the background.
    func enterBackground() {
        profileFetchPaused = true
        profileFlushCancellable?.cancel()
        profileFlushCancellable = nil
        #if DEBUG
        print("NostrService: entering background mode — profile timer paused")
        #endif
    }

    /// Resume the profile-fetch timer when the UI becomes visible.
    func enterForeground() {
        profileFetchPaused = false
        if !profileFetchQueue.isEmpty && profileFlushCancellable == nil {
            setupMetadataFlusher()
        }
        #if DEBUG
        print("NostrService: entering foreground mode — profile timer resumed")
        #endif
    }

    // Used to distinguish live incoming events from historical backfill on startup.
    // Only events newer than this date fire push notifications.
    // Reset each time the app wakes from a silent push so fresh events are "new".
    var sessionStartDate: Date = Date()

    init() {
        setupThrottling()
        loadProfiles()
        updateOwnerHex()
        prefetchWhitelistedProfiles()

        // React to active account switches — tear down old connections and event state.
        // Stored in configCancellable (not cancellables) so resetConnections() won't destroy it.
        configCancellable = ConfigService.shared.activeAccountSwitches
            .sink { [weak self] _ in
                self?.handleAccountSwitch()
            }

        // Handle owner npub changes (e.g. after initial setup)
        ConfigService.shared.$config
            .map { $0.ownerNpub }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateOwnerHex()
                self.prefetchWhitelistedProfiles()
            }
            .store(in: &cancellables)
    }

    @Published var profiles: [String: FeedProfile] = [:]
    var ownerHexPubkey: String = ""

    @Published var profileUpdates = ProfileUpdateSignal()
    var pendingProfileUpdates: Set<String> = []
    var profileUpdateFlushScheduled = false
    var profileUpdateGeneration = 0

    /// The active browsing identity hex pubkey. Falls back to owner if no override is set.
    var activeHexPubkey: String {
        ConfigService.shared.activeAccountHexPubkey
    }

    var lastConnectLog: Date = .distantPast

    /// Asked for profile metadata on top of the broadcast relays; the same list
    /// as Android's `PROFILE_RELAYS`. Without them a profile the phone had not
    /// cached never loaded: of the default broadcast relays nos.lol and
    /// nostr.mom are down and primal lacks most profiles, while purplepag.es
    /// had every one tried (jack, ODELL, fiatjaf; 2026-10-06). offchain.pub
    /// dropped: it refuses connections (2026-10-12).
    static let profileIndexRelays = [
        "wss://relay.damus.io",
        "wss://user.kindpag.es",
        "wss://purplepag.es",
    ]

    // Unified cache structure
    var lastProfileSave: Date = .distantPast
    let profileSaveThrottle: TimeInterval = 5.0

    // MARK: - Global Search

    var globalSearchSession: GlobalSearchSession?
    var mentionSearchSession: GlobalSearchSession?

    // MARK: - Local Relay Search

    var localSearchSession: LocalRelaySearchSession?

    /// Bumped every time `events` is wiped by `resetConnections`. One-shot
    /// fetches whose results live only in `events` (receipts pulled from feed
    /// relays, notes fetched by id) compare against it to know they must run
    /// again; the local relay subscription refills itself, they do not.
    var eventsResetGeneration = 0

    var vertexCache = VertexReputation.Cache()

    /// Posts a blob delete may offer to take down too: notes, picture and
    /// video posts, file metadata and comments. Never a profile (kind 0,
    /// whose picture may be this file), a list, a DM or an article.
    static let blobPostKinds: Set<Int> = [1, 20, 21, 22, 1063, 1111]

    // Per-relay reconnection state to implement exponential backoff
    var relayReconnectAttempts: [String: Int] = [:]
    var relayLastReconnectTime: [String: Date] = [:]
    var relaysReconnecting = Set<String>() // Guard against concurrent reconnects
    let maxReconnectAttempts = 10
    let baseReconnectDelay: TimeInterval = 2.0
    let maxReconnectDelay: TimeInterval = 30.0  // Cap at 30s instead of 60s to reduce freeze perception

    /// What the Relay tab counts as a post: notes, reposts, articles, NIP-22
    /// comments and highlights. Comments and highlights that tag you were
    /// never requested, so they never showed up there.
    static let relayTabNoteKinds = [1, 6, 30023, NIP10Thread.commentKind, 9802, NIP88Poll.kind]

    // MARK: - Quoted Events

    /// Identifiers already requested by `fetchQuotedEvent`, so a row that keeps
    /// reappearing does not re-request the same missing note.
    var quotedEventsInFlight = Set<String>()
}

import Foundation
import Combine
import SwiftUI

@MainActor
class NostrService: ObservableObject {
    static let shared = NostrService()
    // These are no longer @Published to prevent background-thread notification crashes.
    // We notify manually on the main thread via the throttled subject.
    private(set) var events: [NostrEvent] = []
    private(set) var noteMedia: [MediaItem] = []

    /// Max events held in memory for the Viewer/Relay tab. Raised so the user can
    /// scroll back through (effectively) their whole history. The 10k ceiling was
    /// historically a jetsam risk because of full kind-30023 long-form bodies, so
    /// those are bounded separately by `maxLongFormEvents` below — the lightweight
    /// bulk (notes/reactions/zaps) can use the full ceiling without the memory blowup.
    private static let maxEvents = 10_000
    /// Cap on retained full long-form (kind 30023) bodies — these are large, and were
    /// the main contributor to the ~310 MB resident set that made the app the #1 jetsam
    /// target. The newest this many are kept in full; older ones drop off the list.
    private static let maxLongFormEvents = 500
    /// Cap on media items harvested from events for the gallery tab. Unlike `events`
    /// this list was never trimmed, so it grew for the process lifetime — and each
    /// item carries a copy of its source event's full tag list.
    private static let maxNoteMedia = 4_000

    // Aggregated status
    @Published var connectionStatus: String = "Disconnected"
    @Published var connectionColor: String = "gray"
    @Published var isFetching: Bool = false

    /// Set by SceneDelegate when it handles foreground reconnection.
    /// ViewerView checks this to avoid redundant refreshAll() calls.
    var lastForegroundReconnectTime: Date?

    private var seenEventIds = Set<String>()
    /// Guards `seenEventIds`, which is read/written from BOTH the background
    /// `processingQueue` (processMessage) and the main thread (postEvent,
    /// injectEvent, handleAccountSwitch). Without it the concurrent non-atomic
    /// Set mutations corrupt its storage → random EXC_BAD_ACCESS. Always go
    /// through markSeen/hasSeen/clearSeen; never touch `seenEventIds` directly.
    private let seenLock = NSLock()
    private var clients: [String: WebSocketClient] = [:]
    private var activeSubscriptions: [String: String] = [:] // [RelayURL: SubID]
    private var cancellables = Set<AnyCancellable>()
    /// Temporary WebSocketClient instances that aren't stored in `clients`.
    /// Held here to give them a predictable lifetime: they are removed
    /// when they disconnect, rather than relying on Combine sink captures.
    private var temporaryClients: Set<WebSocketClient> = []
    private var configCancellable: AnyCancellable? // Stored separately so resetConnections() doesn't destroy it
    private var statusDowngradeTask: Task<Void, Never>?
    private let processingQueue = DispatchQueue(label: "com.haven.nostr-processing", qos: .userInitiated)

    // Relay List Metadata Cache (Kind 10002)
    @Published var relayLists: [String: [String]] = [:] // [Pubkey: [InboxRelayURLs]]
    @Published var outboxRelays: [String: [String]] = [:] // [Pubkey: [WriteRelayURLs]]
    /// created_at of the kind-10002 event currently reflected in relayLists/outboxRelays,
    /// per pubkey — guards against a late-arriving stale relay list (from a lagging relay)
    /// clobbering a fresher one, same failure mode as the kind-3 follow-list clobber bug.
    private var relayListCreatedAt: [String: Int64] = [:]
    private var relaysInFlight = Set<String>()

    // DM Relay List Cache (Kind 10050 - NIP-17)
    @Published var dmRelayLists: [String: [String]] = [:] // [Pubkey: [DMRelayURLs]]
    private var dmRelaysInFlight = Set<String>()

    // BUD-03: User Server Lists (Kind 10063)
    @Published var serverLists: [String: [String]] = [:] // [Pubkey: [BlossomServerURLs]]

    // Batching updates to the UI
    private let eventUpdateSubject = PassthroughSubject<Void, Never>()

    // Buffered event batching — avoids per-event main thread dispatch
    private var eventBuffer: [(NostrEvent, [MediaItem])] = []
    private let bufferLock = NSLock()
    private var bufferFlushTimer: Timer?

    // Pagination tracking
    private var activeSubscriptionCount = 0
    /// Safety net for `fetchNotes`: force-clears `isFetching` if subscription
    /// EOSEs never arrive (unreachable relay, or a socket torn down mid-fetch),
    /// so the Viewer/Relay "Loading notes…" overlay can never latch indefinitely.
    private var fetchWatchdogTask: Task<Void, Never>?
    private var profilesInFlight = Set<String>()
    private var profileFetchQueue = Set<String>()
    private var profileFlushCancellable: AnyCancellable?

    /// Pause the profile-fetch timer when the UI is hidden to avoid
    /// unnecessary network requests and CPU usage in the background.
    func enterBackground() {
        profileFlushCancellable?.cancel()
        profileFlushCancellable = nil
        #if DEBUG
        print("NostrService: entering background mode — profile timer paused")
        #endif
    }

    /// Resume the profile-fetch timer when the UI becomes visible.
    func enterForeground() {
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
        configCancellable = ConfigService.shared.$config
            .map { $0.activeAccountNpub }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
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
    private(set) var ownerHexPubkey: String = ""

    @Published private(set) var profileUpdates = ProfileUpdateSignal()
    private var pendingProfileUpdates: Set<String> = []
    private var profileUpdateFlushScheduled = false
    private var profileUpdateGeneration = 0

    /// Records that `pubkey`'s profile changed and schedules a coalesced flush
    /// of `profileUpdates`. Must be called on the main thread (all call sites
    /// already are, inside `DispatchQueue.main.async`).
    func noteProfileUpdated(_ pubkey: String) {
        pendingProfileUpdates.insert(pubkey)
        guard !profileUpdateFlushScheduled else { return }
        profileUpdateFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.profileUpdateFlushScheduled = false
            guard !self.pendingProfileUpdates.isEmpty else { return }
            let batch = self.pendingProfileUpdates
            self.pendingProfileUpdates.removeAll(keepingCapacity: true)
            self.profileUpdateGeneration &+= 1
            self.profileUpdates = ProfileUpdateSignal(generation: self.profileUpdateGeneration, pubkeys: batch)
        }
    }

    /// The active browsing identity hex pubkey. Falls back to owner if no override is set.
    var activeHexPubkey: String {
        ConfigService.shared.activeAccountHexPubkey
    }

    private var lastConnectLog: Date = .distantPast
    private func shouldLogConnect() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastConnectLog) > 5.0 {
            lastConnectLog = now
            return true
        }
        return false
    }

    private func updateOwnerHex() {
        let npub = ConfigService.shared.config.ownerNpub
        if let hex = Bech32.decode(npub)?.hexString {
            self.ownerHexPubkey = hex
            #if DEBUG
            print("NostrService: Owner Hex Pubkey: \(hex)")
            #endif
        } else {
            self.ownerHexPubkey = ""
        }
    }

    /// Pre-fetches profiles for the owner + all whitelisted npubs so avatars
    /// are ready when the account switcher is opened.
    private func prefetchWhitelistedProfiles() {
        let allNpubs = ConfigService.shared.allAccountNpubs
        let hexPubkeys = allNpubs.compactMap { npub -> String? in
            let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            return Bech32.decode(trimmed)?.hexString
        }
        fetchMissingProfiles(for: hexPubkeys)
    }

    private func setupMetadataFlusher() {
        profileFlushCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.flushMetadataRequests()
            }
    }

    private func flushMetadataRequests() {
        guard !profileFetchQueue.isEmpty else { return }
        let pubkeys = Array(profileFetchQueue)
        profileFetchQueue.removeAll()

        // Use blastr relays or defaults if empty
        var relays = ConfigService.shared.config.activeBlastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.primal.net", "wss://nos.lol"]
        }

        #if DEBUG
        print("NostrService: Batch fetching metadata for \(pubkeys.count) pubkeys from \(relays.count) Blastr relays")
        #endif

        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }

        for url in uniqueRelays {
            let client = WebSocketClient()
            client.isTemporary = true

            let urlString = url.absoluteString
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self else { return }
                    if state == .connected {
                        self.sendProfileRequest(to: client, pubkeys: pubkeys)
                        // Disconnect after results come in (or reasonable timeout)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            trackTemporaryClient(client)
        }
    }

    private func loadProfiles() {
        self.profiles = ProfileRepository.loadProfiles()
        self.relayLists = ProfileRepository.loadRelayLists()
        self.outboxRelays = ProfileRepository.loadOutboxRelays()
        self.serverLists = ProfileRepository.loadServerLists()
        self.dmRelayLists = ProfileRepository.loadDMRelayLists()
        #if DEBUG
        print("NostrService: Loaded \(profiles.count) profiles, \(relayLists.count) relay lists, \(outboxRelays.count) outbox, \(serverLists.count) servers, \(dmRelayLists.count) DM relays from cache")
        #endif
    }


    // Unified cache structure
    private var lastProfileSave: Date = .distantPast
    private let profileSaveThrottle: TimeInterval = 5.0

    func saveProfilesThrottled() {
        let now = Date()
        if now.timeIntervalSince(lastProfileSave) > profileSaveThrottle {
            lastProfileSave = now
            ProfileRepository.saveProfiles(profiles)
            ProfileRepository.saveRelayLists(relayLists)
            ProfileRepository.saveOutboxRelays(outboxRelays)
            ProfileRepository.saveDMRelayLists(dmRelayLists)
            ProfileRepository.saveServerLists(serverLists)
        }
    }

    func fetchMissingProfiles(for pubkeys: [String], force: Bool = false) {
        let missing = pubkeys.filter { (force || profiles[$0] == nil) && !profilesInFlight.contains($0) }
        guard !missing.isEmpty else { return }

        for pubkey in missing {
            profilesInFlight.insert(pubkey)
            profileFetchQueue.insert(pubkey)
        }

        if profileFlushCancellable == nil {
            setupMetadataFlusher()
        }
    }


    private func sendProfileRequest(to client: WebSocketClient, pubkeys: [String]) {
        let subscriptionId = "meta-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = [
            "kinds": [0, 10002, 10050, 10000, 10063],
            "authors": pubkeys
        ]

        let req = ["REQ", subscriptionId, filter] as [Any]

        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            client.send(text: reqString)
        }
    }

    func fetchRelayList(for pubkey: String) {
        guard (relayLists[pubkey] == nil || dmRelayLists[pubkey] == nil) && !relaysInFlight.contains(pubkey) else { return }
        relaysInFlight.insert(pubkey)

        // Use blastr relays or defaults if empty
        var relays = ConfigService.shared.config.activeBlastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.primal.net", "wss://nos.lol"]
        }

        // Include cached outbox (write) relays for this user — their kind 10002/10050
        // is most likely to be found on their own write relays.
        if let cachedOutbox = outboxRelays[pubkey] {
            for relay in cachedOutbox where !relays.contains(relay) {
                relays.append(relay)
            }
        }

        #if DEBUG
        print("NostrService: Fetching relay list (10002/10050) for \(pubkey.prefix(8))...")
        #endif

        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }

        // Safety net: clear the in-flight guard 10s after the attempt starts
        // regardless of outcome, so a failed fetch can be retried later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.relaysInFlight.remove(pubkey)
        }

        for url in uniqueRelays {
            let client = WebSocketClient()
            client.isTemporary = true

            let urlString = url.absoluteString
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let subscriptionId = "relays-\(UUID().uuidString.prefix(8))"
                        let filter: [String: Any] = [
                            "kinds": [10002, 10050],
                            "authors": [pubkey],
                            "limit": 2
                        ]

                        let req = ["REQ", subscriptionId, filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqString = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqString)
                        }

                        // Disconnect after reasonable timeout
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            trackTemporaryClient(client)
        }
    }

    // MARK: - Global (NIP-50) Search

    private var globalSearchClients: [WebSocketClient] = []
    private var globalSearchCancellables = Set<AnyCancellable>()

    /// NIP-50 global search across public search relays. Connects to external
    /// search-capable relays, sends a REQ with a `search` filter for notes
    /// (kind 1) and profiles (kind 0), collects results until a timeout, then
    /// returns parsed FeedNotes/FeedProfiles on the main thread. Any prior
    /// in-flight global search is cancelled first.
    func globalSearch(query: String, completion: @escaping (GlobalSearchResults) -> Void) {
        cancelGlobalSearch()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            completion(GlobalSearchResults())
            return
        }

        let relays = nip50SearchRelays.compactMap { URL(string: $0) }
        guard !relays.isEmpty else {
            completion(GlobalSearchResults())
            return
        }

        let collector = GlobalSearchCollector()
        let subId = "gsearch-\(UUID().uuidString.prefix(8))"
        var didFinish = false

        let finish: () -> Void = { [weak self] in
            guard let self = self else { return }
            if didFinish { return }
            didFinish = true
            let results = collector.snapshot()
            self.cancelGlobalSearch()
            DispatchQueue.main.async {
                // Merge discovered profiles into the shared cache so avatars/names render.
                for profile in results.profiles where self.profiles[profile.pubkey] == nil {
                    self.profiles[profile.pubkey] = profile
                }
                completion(results)
            }
        }

        for url in relays {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: processingQueue)
                .sink { message in
                    collector.ingest(message: message, subId: subId)
                }
                .store(in: &globalSearchCancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let notesFilter: [String: Any] = ["kinds": [1], "search": trimmed, "limit": 30]
                        let profileFilter: [String: Any] = ["kinds": [0], "search": trimmed, "limit": 20]
                        let req = ["REQ", subId, notesFilter, profileFilter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &globalSearchCancellables)

            client.connect(url: url)
            globalSearchClients.append(client)
        }

        // Return whatever was collected after a fixed window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            finish()
        }
    }

    /// Tears down any in-flight global search connections.
    func cancelGlobalSearch() {
        for client in globalSearchClients { client.disconnect() }
        globalSearchClients.removeAll()
        globalSearchCancellables.removeAll()
    }

    // MARK: - Local Relay Search

    private var localSearchSession: LocalRelaySearchSession?

    /// Searches everything the embedded relay has stored, not just whatever the
    /// feed subscription has already loaded into memory.
    ///
    /// Three things this has to get right:
    ///
    /// 1. **Every route.** haven serves several stores off one port and they
    ///    hold different things: `/` is the outbox and only ever accepts events
    ///    the owner signed (`MustBeWhitelistedToPost`), the follows' notes live
    ///    on `/feed`, and notes that tag the owner live on `/inbox`. Searching
    ///    `/` alone means searching your own posts.
    /// 2. **Paging.** The LMDB backend honours a limit only up to 1500 and
    ///    quietly drops anything larger to 375 — see `LocalRelaySearchPlan`. A
    ///    single REQ cannot cover the store, so each route/kind is paged with an
    ///    `until` cursor until it runs dry.
    /// 3. **Finishing on EOSE.** The relay is on-box and answers in
    ///    milliseconds; a fixed timer would make every search take that long.
    ///    The timeout below is a fallback for a socket that never replies.
    ///
    /// The relay's backends no-op any filter with `search` set, so matching is
    /// done client-side; profiles already in the in-memory cache are matched too,
    /// because no local store holds anyone else's kind 0.
    func localRelaySearch(query: String, relayURL: URL, completion: @escaping (GlobalSearchResults) -> Void) {
        cancelLocalRelaySearch()

        guard let matcher = LocalSearchMatcher(query: query) else {
            completion(GlobalSearchResults())
            return
        }

        let base = relayURL.absoluteString
        let routes = [base, base + "/feed", base + "/inbox"].compactMap { URL(string: $0) }

        let session = LocalRelaySearchSession(matcher: matcher, routes: routes) { [weak self] results in
            guard let self = self else { return }
            DispatchQueue.main.async {
                for profile in results.profiles where self.profiles[profile.pubkey] == nil {
                    self.profiles[profile.pubkey] = profile
                }
                completion(results)
            }
        }
        localSearchSession = session
        session.addCachedProfiles(profiles)
        session.start()
    }

    /// Tears down any in-flight local relay search connections.
    func cancelLocalRelaySearch() {
        localSearchSession?.cancel()
        localSearchSession = nil
    }

    /// Registers a temporary client in `temporaryClients` and arranges
    /// for it to be removed when it disconnects or errors out.
    private func trackTemporaryClient(_ client: WebSocketClient) {
        temporaryClients.insert(client)
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self = self, let client = client else { return }
                if state == .disconnected || state == .error {
                    self.temporaryClients.remove(client)
                }
            }
            .store(in: &cancellables)
    }

    func resetConnections() {
        for (urlString, subId) in activeSubscriptions {
            if let client = clients[urlString] {
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    client.send(text: closeStr)
                }
            }
        }
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
        activeSubscriptions.removeAll()
        relaysReconnecting.removeAll()
        // Disconnect temporary clients BEFORE clearing cancellables so their
        // ping timers are cancelled via the normal disconnectLocked() path.
        for client in temporaryClients { client.disconnect() }
        temporaryClients.removeAll()
        cancellables.removeAll()
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil
        bufferLock.lock()
        eventBuffer.removeAll()
        bufferLock.unlock()
        setupThrottling()
    }

    /// Resets all WebSocket state when the active account changes.
    /// Unlike resetConnections(), this preserves the config observer and
    /// also clears per-account event/media state (Viewer tab).
    private func handleAccountSwitch() {
        // 1. Send CLOSE for all active relay subscriptions, then disconnect
        for (urlString, subId) in activeSubscriptions {
            if let client = clients[urlString] {
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    client.send(text: closeStr)
                }
            }
        }
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
        activeSubscriptions.removeAll()
        relaysReconnecting.removeAll()

        // Disconnect temporary clients BEFORE clearing cancellables so their
        // ping timers are cancelled via the normal disconnectLocked() path.
        for client in temporaryClients { client.disconnect() }
        temporaryClients.removeAll()

        // Cancel stale connection-state sinks from the previous account's
        // WebSocket clients. Without this, orphaned sinks fire
        // updateAggregatedStatus() with dead clients and can trigger phantom
        // reconnection attempts for URLs that no longer exist.
        cancellables.removeAll()
        setupThrottling()

        // 2. Clear Viewer tab event state — these belong to the previous account
        events.removeAll()
        noteMedia.removeAll()
        clearSeen()

        // 3. Flush pending event buffer
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil
        bufferLock.lock()
        eventBuffer.removeAll()
        bufferLock.unlock()

        // 4. Reset fetch/subscription tracking
        isFetching = false
        activeSubscriptionCount = 0
        cancelFetchWatchdog()

        // 5. Clear reconnect backoff state
        relayReconnectAttempts.removeAll()
        relayLastReconnectTime.removeAll()

        // 6. Notify UI of cleared state
        eventUpdateSubject.send()

        // 7. Update identity and prefetch avatars for the new account
        updateOwnerHex()
        prefetchWhitelistedProfiles()

        // 8. Re-establish relay connections for the new account.
        // Previously this step was missing — the teardown above left the
        // Viewer tab with zero WebSocket clients, so the relay indicator
        // went yellow → red and the feed stayed empty until pull-to-refresh.
        reconnectForActiveAccount()

        #if DEBUG
        print("NostrService: Account switch — reset connections and reconnected for new account")
        #endif
    }

    /// Builds relay URLs and author filters from the current config and
    /// opens fresh WebSocket connections for the Viewer tab.
    private func reconnectForActiveAccount() {
        let config = ConfigService.shared.config

        var urls = [config.nostrURL, config.nostrURL + "/inbox"]
            .compactMap { URL(string: $0) }

        let macURL = config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty {
            if let macRelay = URL(string: macURL) { urls.append(macRelay) }
            if let macInbox = URL(string: macURL + "/inbox") { urls.append(macInbox) }
        }

        guard !urls.isEmpty else { return }

        var authorsSet = Set<String>()
        if !ownerHexPubkey.isEmpty {
            authorsSet.insert(ownerHexPubkey)
        }
        for pk in ConfigService.shared.whitelistedHexPubkeys {
            authorsSet.insert(pk)
        }

        fetchNotes(from: urls, authors: Array(authorsSet))
    }

    private func setupThrottling() {
        // Debounce UI updates to prevent main thread saturation and fix NSStatusItem threading crash
        eventUpdateSubject
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Publishing

    /// Signs an event using the stored nsec via the Go backend
    /// - Parameters:
    ///   - kind: The event kind
    ///   - content: The event content
    ///   - tags: The event tags
    ///   - password: Optional password for NIP-49 encrypted keys. If not provided, will attempt to retrieve from Keychain.
    /// - Returns: The signed NostrEvent, or nil if signing fails
    /// - Parameter signAsNpub: Sign as this specific account instead of whichever is
    ///   currently active, WITHOUT touching config.activeAccountNpub. Use this for any
    ///   publish that targets a non-active account (e.g. syncing a secondary account's
    ///   mute/relay list) — temporarily mutating the shared active-account pointer is
    ///   observed by every subscriber (FeedService/NostrService's own account-switch
    ///   handlers), making a background publish look like a real user-driven switch.
    func signEvent(kind: Int, content: String, tags: [[String]] = [], password: String? = nil, forceOwner: Bool = false, signAsNpub: String? = nil) -> NostrEvent? {
        var sk: String?
        let config = ConfigService.shared.config

        // Determine which account is signing
        let activeNpub = (signAsNpub ?? config.activeAccountNpub).trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = forceOwner || activeNpub.isEmpty || activeNpub == config.ownerNpub
        
        if signingAsOwner {
            // ── Owner signing path (existing logic) ──────────────────────────
            if !config.ownerNcryptsec.isEmpty {
                let pwd = password ?? NIP49Service.getPasswordFromKeychain()
                if let pwd = pwd {
                    do {
                        sk = try config.getDecryptedHexKey(password: pwd)
                    } catch {
                        print("NostrService: NIP-49 decrypt failed: \(error.localizedDescription)")
                        return nil
                    }
                } else {
                    print("NostrService: NIP-49 key exists but no password in Keychain")
                    return nil
                }
            } else {
                sk = config.ownerHexKey
            }
        } else {
            // ── Whitelisted account signing path ─────────────────────────────
            do {
                if let hexKey = try ConfigService.shared.getCredentialHexKey(forNpub: activeNpub) {
                    sk = hexKey
                } else {
                    // No credential stored — do NOT fall back to owner key, as that
                    // would silently post from the wrong account.
                    print("NostrService: No credential for active account \(activeNpub.prefix(16))..., cannot sign")
                    return nil
                }
            } catch {
                print("NostrService: Failed to decrypt whitelisted account key: \(error.localizedDescription)")
                return nil
            }
        }

        guard let sk = sk, !sk.isEmpty else {
            print("NostrService: Cannot sign - no private key available")
            return nil
        }

        // Use the signing account's pubkey for the event — decoded directly from
        // activeNpub (which already reflects signAsNpub when provided) rather than
        // the cached activeHexPubkey, which only ever reflects the real active account.
        let signingPubkey = signingAsOwner ? ownerHexPubkey : (Bech32.decode(activeNpub)?.hexString ?? activeHexPubkey)

        let finalTags = EventPublisher.appendClientTag(to: tags, kind: kind)
        let eventDict = EventPublisher.buildUnsignedEvent(pubkey: signingPubkey, kind: kind, content: content, tags: finalTags)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            print("NostrService: Failed to serialize event to JSON")
            return nil
        }

        return EventPublisher.signWithGoBackend(eventJSON: jsonStr, secretKey: sk)
    }

    /// Async variant of signEvent that supports both local key and NIP-46 remote signing.
    /// When signingMode is "nip46", delegates to NIP46Service. Otherwise wraps the local signEvent().
    /// - Parameter signAsNpub: See signEvent(_:signAsNpub:) — signs as this account
    ///   without touching config.activeAccountNpub. NIP-46 mode ignores it (falls back
    ///   to whatever the active bunker connection is already signing for), since a
    ///   background publish can't switch bunker connections without user interaction.
    func signEventAsync(kind: Int, content: String, tags: [[String]] = [], password: String? = nil, forceOwner: Bool = false, signAsNpub: String? = nil) async -> NostrEvent? {
        let config = ConfigService.shared.config
        let mode = config.activeSigningMode()
        print("NostrService: signEventAsync mode=\(mode) activeNpub=\(config.activeAccountNpub.prefix(20)) ownerNpub=\(config.ownerNpub.prefix(20)) forceOwner=\(forceOwner)")

        if mode == "nip46" {
            // Determine the signing pubkey from the active account (or owner if forced)
            let signingPubkey = forceOwner ? ownerHexPubkey : activeHexPubkey

            guard !signingPubkey.isEmpty else {
                print("NostrService: NIP-46 sign failed - no pubkey available")
                return nil
            }

            let finalTags = EventPublisher.appendClientTag(to: tags, kind: kind)
            let eventDict = EventPublisher.buildUnsignedEvent(pubkey: signingPubkey, kind: kind, content: content, tags: finalTags)

            guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                print("NostrService: NIP-46 sign failed - JSON serialization error")
                return nil
            }

            do {
                print("NostrService: NIP-46 signing kind \(kind) event (tags=\(finalTags.map { $0.first ?? "?" })), sending to bunker…")
                print("NostrService: NIP-46 outgoing event JSON: \(jsonStr.prefix(500))")
                let signedJSON = try await NIP46Service.shared.signEvent(eventJSON: jsonStr)
                print("NostrService: NIP-46 bunker returned \(signedJSON.prefix(300))")
                guard let signedData = signedJSON.data(using: .utf8) else {
                    print("NostrService: NIP-46 sign failed - response not valid UTF-8")
                    return nil
                }
                let event = try JSONDecoder().decode(NostrEvent.self, from: signedData)
                print("NostrService: NIP-46 signed event id=\(event.id.prefix(8)) pubkey=\(event.pubkey.prefix(8)) sig=\(event.sig.prefix(8))")
                return event
            } catch {
                print("NostrService: NIP-46 sign FAILED for kind \(kind): \(error)")
                if kind == 24242 {
                    print("NostrService: Blossom auth (kind 24242) signing failed — remote signer may not support this event kind or may require manual approval")
                }
                return nil
            }
        } else {
            return signEvent(kind: kind, content: content, tags: tags, password: password, forceOwner: forceOwner, signAsNpub: signAsNpub)
        }
    }

    // MARK: - Proof of Work Mining + Signing

    /// Resolves the secret key and builds the unsigned-event JSON for local signing.
    /// Runs on the main actor (touches config/Keychain); returns Sendable primitives so
    /// the heavy mine+sign can be handed to a background executor without crossing actors.
    private func prepareLocalSigning(kind: Int, content: String, tags: [[String]], password: String?, forceOwner: Bool) -> (jsonStr: String, secretKey: String)? {
        var sk: String?
        let config = ConfigService.shared.config

        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = forceOwner || activeNpub.isEmpty || activeNpub == config.ownerNpub

        if signingAsOwner {
            if !config.ownerNcryptsec.isEmpty {
                let pwd = password ?? NIP49Service.getPasswordFromKeychain()
                if let pwd = pwd {
                    do {
                        sk = try config.getDecryptedHexKey(password: pwd)
                    } catch {
                        print("NostrService: NIP-49 decrypt failed: \(error.localizedDescription)")
                        return nil
                    }
                } else {
                    print("NostrService: NIP-49 key exists but no password in Keychain")
                    return nil
                }
            } else {
                sk = config.ownerHexKey
            }
        } else {
            do {
                if let hexKey = try ConfigService.shared.getCredentialHexKey(forNpub: activeNpub) {
                    sk = hexKey
                } else {
                    print("NostrService: No credential for active account \(activeNpub.prefix(16))..., cannot sign")
                    return nil
                }
            } catch {
                print("NostrService: Failed to decrypt whitelisted account key: \(error.localizedDescription)")
                return nil
            }
        }

        guard let sk = sk, !sk.isEmpty else {
            print("NostrService: Cannot sign - no private key available")
            return nil
        }

        let signingPubkey = signingAsOwner ? ownerHexPubkey : activeHexPubkey
        let finalTags = EventPublisher.appendClientTag(to: tags, kind: kind)
        let eventDict = EventPublisher.buildUnsignedEvent(pubkey: signingPubkey, kind: kind, content: content, tags: finalTags)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            print("NostrService: Failed to serialize event to JSON")
            return nil
        }

        return (jsonStr, sk)
    }

    /// Signs an event with NIP-13 Proof of Work mining via the Go backend.
    /// When difficulty > 0, mines a nonce tag before signing. Falls back to plain signing on failure.
    ///
    /// NOTE: PoW mining is a tight CPU loop (up to `maxAttempts` SHA256 hashes). This synchronous
    /// entry point runs it on the calling thread — for the main actor, prefer `mineAndSignEventAsync`,
    /// which offloads the mine to a background executor so the UI/run loop stays responsive.
    func mineAndSignEvent(kind: Int, content: String, tags: [[String]] = [], difficulty: Int = 0, maxAttempts: Int = 10_000_000, password: String? = nil, forceOwner: Bool = false) -> NostrEvent? {
        guard let prep = prepareLocalSigning(kind: kind, content: content, tags: tags, password: password, forceOwner: forceOwner) else {
            return nil
        }
        return EventPublisher.mineAndSignWithGoBackend(eventJSON: prep.jsonStr, secretKey: prep.secretKey, difficulty: difficulty, maxAttempts: maxAttempts)
    }

    /// Async variant of mineAndSignEvent that supports NIP-46 remote signing.
    /// For NIP-46 mode: skips PoW (no secret key available) and delegates to signEventAsync.
    /// For local mode: mines PoW and signs via the Go backend on a background executor so the
    /// main thread is never blocked by the mining loop (which would otherwise trip the iOS watchdog).
    func mineAndSignEventAsync(kind: Int, content: String, tags: [[String]] = [], difficulty: Int = 0, maxAttempts: Int = 10_000_000, password: String? = nil) async -> NostrEvent? {
        let config = ConfigService.shared.config
        let mode = config.activeSigningMode()

        if mode == "nip46" {
            // NIP-46: we don't have the secret key, so skip PoW
            return await signEventAsync(kind: kind, content: content, tags: tags, password: password)
        }

        // Resolve key + build JSON on the main actor (Keychain/config access)…
        guard let prep = prepareLocalSigning(kind: kind, content: content, tags: tags, password: password, forceOwner: false) else {
            return nil
        }
        // …then mine + sign off the main thread. `mineAndSignWithGoBackend` is a non-isolated
        // static func operating only on the Sendable Strings we pass in.
        let jsonStr = prep.jsonStr
        let secretKey = prep.secretKey
        return await Task.detached(priority: .userInitiated) {
            EventPublisher.mineAndSignWithGoBackend(eventJSON: jsonStr, secretKey: secretKey, difficulty: difficulty, maxAttempts: maxAttempts)
        }.value
    }

    /// Publishes a signed Kind 10000 (Mute List) event to configured relays for the active account
    @MainActor
    func publishMuteList(for accountNpub: String, blockedNpubs: [String]) {
        // Convert npubs to hex pubkeys
        let hexKeys = blockedNpubs.compactMap { npub -> String? in
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            return Bech32.decode(clean)?.hexString
        }

        let tags = hexKeys.map { ["p", $0] }

        Task {
            if let event = await signEventAsync(kind: 10000, content: "", tags: tags, signAsNpub: accountNpub) {
                postEvent(event)
                ConfigService.shared.config.blockedNpubsLastSyncTimestamp[accountNpub] = event.created_at
                ConfigService.shared.save()
                #if DEBUG
                print("NostrService: Successfully published Kind 10000 mute list with \(tags.count) tags for \(accountNpub.prefix(8))")
                #endif
            } else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10000 mute list for \(accountNpub.prefix(8))")
                #endif
            }
        }
    }

    /// BUD-03: Publishes a Kind 10063 (User Server List) event advertising Blossom mirrors.
    /// Call whenever blossomMirrors changes (settings, setup wizard).
    /// Pass fipsDetectedNpub when available to include the detected .fips address.
    @MainActor
    func publishServerList(fipsDetectedNpub: String? = nil) {
        let mirrors = ConfigService.shared.config.activeBlossomMirrors(detectedNpub: fipsDetectedNpub)
        guard !mirrors.isEmpty else {
            #if DEBUG
            print("NostrService: No Blossom mirrors configured, skipping Kind 10063 publish")
            #endif
            return
        }

        // Build ["server", url] tags — ordered by reliability (local relay first via activeBlossomMirrors)
        let tags = mirrors.map { ["server", $0] }

        Task {
            if let event = await signEventAsync(kind: 10063, content: "", tags: tags) {
                postEvent(event)
                #if DEBUG
                print("NostrService: Published Kind 10063 server list with \(tags.count) servers")
                #endif
            } else {
                print("NostrService: Failed to sign Kind 10063 server list")
            }
        }
    }

    /// A loopback address means "this machine". Advertising one to the network,
    /// or publishing someone else's DM to one, sends the event to the *sender's*
    /// own relay — the write succeeds, nothing errors, and the recipient never
    /// sees it. Never let one reach a relay list or a publish target.
    static func isLoopbackRelay(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else {
            let lowered = urlString.lowercased()
            return lowered.contains("127.0.0.1") || lowered.contains("localhost") || lowered.contains("[::1]")
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0"
    }

    /// NIP-17: Publishes a Kind 10050 (DM Relay List) event advertising which relays to send DMs to.
    /// Call whenever relay preferences change or during initial setup.
    ///
    /// Loopback entries are stripped: this list tells *other people* where to
    /// deliver, and our own 127.0.0.1 is meaningless to them. We previously
    /// inserted it at position 0, so every sender delivered our DMs into their
    /// own local relay and we received nothing.
    @MainActor
    func publishDMRelayList(dmRelays: [String], signAsNpub: String? = nil) {
        let reachable = dmRelays.filter { !Self.isLoopbackRelay($0) }
        guard !reachable.isEmpty else {
            print("NostrService: No externally reachable DM relays, skipping Kind 10050 publish")
            return
        }

        // Build ["r", relay_url] tags for DM relays
        let tags = reachable.map { ["r", $0] }

        Task {
            if let event = await signEventAsync(kind: 10050, content: "", tags: tags, signAsNpub: signAsNpub) {
                postEvent(event)
                #if DEBUG
                print("NostrService: Published Kind 10050 DM relay list with \(tags.count) relays")
                #endif
            } else {
                print("NostrService: Failed to sign Kind 10050 DM relay list")
            }
        }
    }

    /// Republishes kind 10050 for every account that can sign.
    ///
    /// Builds shipped a 10050 that led with `wss://127.0.0.1:<port>`, which made
    /// those accounts undeliverable — senders wrote the gift wrap to their own
    /// machine. 10050 is a replaceable event, so putting a clean one out
    /// overwrites the broken one on every relay that holds it, and from then on
    /// *any* sender reaches them, including ones still running the old build.
    /// That's why this isn't gated behind the publish-relay-list toggle the way
    /// kind 10002 is: a broken 10050 silently breaks DMs, so healing it can't be
    /// opt-in.
    @MainActor
    func republishDMRelayListsForSignableAccounts() {
        let config = ConfigService.shared.config
        guard !config.isLocal else { return }

        let reachable = config.dmRelays.filter { !Self.isLoopbackRelay($0) }
        guard !reachable.isEmpty else { return }

        var accounts: [String] = config.whitelistedNpubs
        if !config.ownerNpub.isEmpty && !accounts.contains(config.ownerNpub) {
            accounts.insert(config.ownerNpub, at: 0)
        }

        Task {
            for npub in accounts {
                let isOwner = npub == config.ownerNpub
                let canSign = isOwner
                    ? (!config.ownerNcryptsec.isEmpty || config.ownerHexKey != nil || ConfigService.shared.hasBunkerConfig(forNpub: npub))
                    : (ConfigService.shared.hasCredential(forNpub: npub) || ConfigService.shared.hasBunkerConfig(forNpub: npub))
                guard canSign else { continue }

                publishDMRelayList(dmRelays: reachable, signAsNpub: npub)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// NIP-65: Publishes a Kind 10002 (Relay List Metadata) event advertising this relay
    /// as the account's inbox. Call when the user enables the toggle or on app launch.
    @MainActor
    func publishRelayList(forNpub accountNpub: String) {
        let config = ConfigService.shared.config
        guard !config.isLocal else {
            #if DEBUG
            print("NostrService: Relay is local-only, skipping Kind 10002 publish")
            #endif
            return
        }

        let publicURL = "wss://\(config.sanitizedRelayURL)"

        // Build NIP-65 tags: no marker means both read and write
        var tags: [[String]] = [["r", publicURL]]

        // Include the Mac relay in the relay list if configured (both platforms)
        let macRelay = config.macRelayWssURL
        if !macRelay.isEmpty {
            tags.append(["r", macRelay])
        }

        Task {
            if let event = await signEventAsync(kind: 10002, content: "", tags: tags, signAsNpub: accountNpub) {
                postEvent(event)
                #if DEBUG
                print("NostrService: Published Kind 10002 relay list for \(accountNpub.prefix(8)) with \(tags.count) relays")
                #endif
            } else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10002 relay list for \(accountNpub.prefix(8))")
                #endif
            }
        }
    }

    /// Publishes Kind 10002 relay list for all accounts that have the setting enabled.
    @MainActor
    func publishRelayListsForEnabledAccounts() {
        let config = ConfigService.shared.config
        guard !config.isLocal else { return }

        let enabledAccounts = config.publishRelayListPerAccount.filter { $0.value }.map { $0.key }
        guard !enabledAccounts.isEmpty else { return }

        Task {
            for npub in enabledAccounts {
                // Verify the account can sign
                let isOwner = npub == config.ownerNpub
                let canSign = isOwner
                    ? (!config.ownerNcryptsec.isEmpty || config.ownerHexKey != nil || ConfigService.shared.hasBunkerConfig(forNpub: npub))
                    : (ConfigService.shared.hasCredential(forNpub: npub) || ConfigService.shared.hasBunkerConfig(forNpub: npub))
                guard canSign else { continue }

                publishRelayList(forNpub: npub)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Posts an event to the local relay and broadcasts to configured relays
    func postEvent(_ event: NostrEvent) {
        print("NostrService: postEvent called – id=\(event.id.prefix(8)) kind=\(event.kind) sig=\(event.sig.prefix(8))")
        // Note: the relay-activity red dot is driven solely by inbound events from
        // others (see RelayProcessManager), so self-authored posts never trigger it.

        // Update local state immediately for instant feedback
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.markSeen(event.id) {
                self.events.insert(event, at: 0)
                self.events.sort(by: { $0.created_at > $1.created_at })

                // Extract media URLs and add to noteMedia
                let urls = self.extractMediaURLs(from: event.content)
                let items = urls.map { url in
                    let mime = Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime)
                }
                if !items.isEmpty {
                    self.noteMedia.append(contentsOf: items)
                }

                self.eventUpdateSubject.send()
            }
        }

        let eventDict: [String: Any] = [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ]

        let msg = ["EVENT", eventDict] as [Any]

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        // Cache raw event JSON immediately so rebroadcast + NIP-18 repost embedding
        // work without waiting for the event to echo back from the relay.
        if event.kind == 1 || event.kind == 6 || event.kind == 30023 {
            if let evData = try? JSONSerialization.data(withJSONObject: eventDict, options: []),
               let evJSON = String(data: evData, encoding: .utf8) {
                FeedService.shared.cacheRawEvent(id: event.id, json: evJSON)
            }
        }

        // 1. Post to local relay — reuse the feed's already-connected socket
        // (the nostr way: one connection, send EVENT through it, no new TLS handshake)
        let relayReady = RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting
        if relayReady {
            let localURLString = ConfigService.shared.config.nostrURL
            if FeedService.shared.sendToLocalRelay(str) {
                // Sent through existing feed connection
            } else if let existing = clients[localURLString], existing.connectionState == .connected {
                existing.send(text: str)
            } else if let localURL = URL(string: localURLString) {
                // Last resort: temporary client
                let localClient = WebSocketClient()
                localClient.isTemporary = true

                localClient.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        if state == .connected {
                            localClient.send(text: str)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                localClient.disconnect()
                            }
                        }
                    }
                    .store(in: &cancellables)

                localClient.connect(url: localURL)
                trackTemporaryClient(localClient)
            }
        } else {
            print("NostrService: ⚠️ Local relay not ready — event \(event.id.prefix(8)) will reach network via direct blast only")
        }

        // 2. Smart Broadcast: Send to author's inbox relays if it's a reply or reaction
        if event.kind == 1 || event.kind == 6 || event.kind == 7 {
            // Find target author's pubkey from 'p' tags (skipping own pubkey)
            let targetPubkey = event.tags.first { $0.count >= 2 && $0[0] == "p" && $0[1] != activeHexPubkey }?[1]

            if let targetPubkey = targetPubkey, let targetRelays = relayLists[targetPubkey] {
                #if DEBUG
                print("NostrService: Smart broadcast event \(event.id.prefix(8)) to \(targetPubkey.prefix(8))'s inbox relays: \(targetRelays)")
                #endif

                let blastrRelays = ConfigService.shared.config.activeBlastrRelays
                for relayURLString in targetRelays {
                    // Skip relays already covered by the direct blast
                    if blastrRelays.contains(relayURLString) { continue }

                    guard let url = URL(string: relayURLString) else { continue }
                    let smartClient = WebSocketClient()
                    smartClient.isTemporary = true

                    smartClient.$connectionState
                        .receive(on: DispatchQueue.main)
                        .sink { state in
                            if state == .connected {
                                smartClient.send(text: str)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    smartClient.disconnect()
                                }
                            }
                        }
                        .store(in: &cancellables)

                    smartClient.connect(url: url)
                    trackTemporaryClient(smartClient)
                }
            } else if let targetPubkey = targetPubkey {
                // We don't have their relays yet, fetch for next time
                fetchRelayList(for: targetPubkey)
            }
        }

        // 3. Profile Broadcast: Send Kind 0 to blastr relays directly
        //    (replaceable events don't trigger the Go relay's StoreEvent blast)
        if event.kind == 0 {
            broadcastRawEvent(eventDict)
        }

    }

    /// Broadcasts a raw signed event dict (including sig) to configured Blastr relays.
    /// Use this to re-broadcast an existing event without re-signing it.
    /// If `onRelayResult` is provided, it's called for each relay with (relayURL, success, message).
    func broadcastRawEvent(_ eventDict: [String: Any], onRelayResult: ((String, Bool, String) -> Void)? = nil) {
        let msg = ["EVENT", eventDict] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        var relays = ConfigService.shared.config.activeBlastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.primal.net", "wss://nos.lol"]
        }

        for urlStr in relays {
            guard let url = URL(string: urlStr) else { continue }
            let client = WebSocketClient()
            client.isTemporary = true
            var hasReported = false

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard !hasReported,
                          let msgData = message.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: msgData) as? [Any],
                          json.count >= 3,
                          let type = json[0] as? String,
                          type == "OK" else { return }
                    hasReported = true
                    let success = json[2] as? Bool ?? false
                    let relayMsg = json.count >= 4 ? (json[3] as? String ?? "") : ""
                    onRelayResult?(urlStr, success, relayMsg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        client.send(text: str)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            guard !hasReported else { return }
                            hasReported = true
                            onRelayResult?(urlStr, false, "timeout")
                            client.disconnect()
                        }
                    } else if state == .error && !hasReported {
                        hasReported = true
                        onRelayResult?(urlStr, false, "connection failed")
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            trackTemporaryClient(client)
        }
    }

    /// Reports an event using Kind 1984
    /// - Parameters:
    ///   - eventId: The ID of the event being reported
    ///   - pubkey: The pubkey of the event author
    ///   - reason: Short reason for reporting (e.g., "spam", "illegal")
    ///   - description: Optional additional details
    func reportEvent(eventId: String, pubkey: String, reason: String, description: String? = nil) {
        var tags = [
            ["e", eventId, "", "report"],
            ["p", pubkey]
        ]

        // Add reason-specific tag if provided
        if !reason.isEmpty {
            tags.append(["reason", reason])
        }

        Task {
            guard let signed = await signEventAsync(kind: 1984, content: description ?? "Reported for \(reason)", tags: tags) else {
                print("NostrService: Failed to sign reporting event")
                return
            }
            postEvent(signed)
            #if DEBUG
            print("NostrService: Posted Kind 1984 report for event \(eventId)")
            #endif
        }
    }

    /// Reports a user using Kind 1984
    /// - Parameters:
    ///   - pubkey: The pubkey of the user being reported
    ///   - reason: Short reason for reporting (e.g., "spam", "illegal")
    ///   - description: Optional additional details
    func reportUser(pubkey: String, reason: String, description: String? = nil) {
        var tags = [
            ["p", pubkey]
        ]

        if !reason.isEmpty {
            tags.append(["reason", reason])
        }

        Task {
            guard let signed = await signEventAsync(kind: 1984, content: description ?? "Reported user for \(reason)", tags: tags) else {
                print("NostrService: Failed to sign user reporting event")
                return
            }
            postEvent(signed)
            #if DEBUG
            print("NostrService: Posted Kind 1984 report for user \(pubkey)")
            #endif
        }
    }

    /// Publishes a NIP-09 deletion request (kind 5) for the given event ID
    func deleteNote(id: String) {
        Task {
            guard let signed = await signEventAsync(kind: 5, content: "", tags: [["e", id]]) else {
                print("NostrService: Failed to sign deletion event")
                return
            }
            postEvent(signed)
            #if DEBUG
            print("NostrService: Posted Kind 5 deletion request for event \(id)")
            #endif
        }
    }

    // Per-relay reconnection state to implement exponential backoff
    private var relayReconnectAttempts: [String: Int] = [:]
    private var relayLastReconnectTime: [String: Date] = [:]
    private var relaysReconnecting = Set<String>() // Guard against concurrent reconnects
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 2.0
    private let maxReconnectDelay: TimeInterval = 30.0  // Cap at 30s instead of 60s to reduce freeze perception

    /// Adds 0-2s random jitter to prevent all clients reconnecting simultaneously after a network drop
    private func delayWithJitter(attempts: Int) -> TimeInterval {
        let base = min(baseReconnectDelay * pow(2.0, Double(attempts)), maxReconnectDelay)
        let jitter = Double.random(in: 0...2.0)
        return base + jitter
    }

    // Check if URL is the local relay
    private func isLocalRelay(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? 80
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" ||
               (host == "127.0.0.1" && port == 3355) ||
               (host == "localhost" && port == 3355)
    }

    // Check if local relay is ready (not booting)
    private var isLocalRelayReady: Bool {
        // Check if relay manager says it's running AND not booting
        return RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting
    }

    func fetchNotes(from relayURLs: [URL], until: Int64? = nil, since: Int64? = nil, authors: [String]? = nil) {
        // Count only the subscriptions we actually open/request below — NOT every
        // URL passed in. Skipped URLs (local relay not ready, already connecting,
        // reconnecting, or backing off) never deliver an EOSE, so pre-counting
        // them with `relayURLs.count` left `activeSubscriptionCount` stuck above 0
        // and wedged `isFetching` true forever — the "Loading notes…" overlay that
        // hangs after an account switch. `awaiting` is tallied as we go and the
        // fetch state is committed once, after the loop.
        var awaiting = 0
        for url in relayURLs {
            let urlString = url.absoluteString

            // Skip local relay if it's still booting - prevents connection spam during boot
            // This guard is critical: prevents 10-second timeout freezes during relay boot
            if isLocalRelay(url) && !isLocalRelayReady {
                #if DEBUG
                if shouldLogConnect() {
                    print("NostrService: Skipping local relay - RelayProcessManager not ready (isRunning=\(RelayProcessManager.shared.isRunning), isBooting=\(RelayProcessManager.shared.isBooting))")
                }
                #endif
                continue
            }

            if let existing = clients[urlString] {
                if existing.connectionState == .connected {
                    sendRequest(to: existing, url: url, until: until, since: since, authors: authors)
                    awaiting += 1
                    continue
                } else if existing.connectionState == .connecting {
                    // Its own connectionState sink will send the request once
                    // connected and produce an EOSE — don't double-count it here.
                    continue
                }
            }

            // Prevent concurrent reconnection attempts for the same URL
            if relaysReconnecting.contains(urlString) {
                #if DEBUG
                print("NostrService: Skipping \(urlString) - reconnection already in progress")
                #endif
                continue
            }

            // Check if we should delay reconnect (exponential backoff)
            if let lastAttempt = relayLastReconnectTime[urlString],
               let attempts = relayReconnectAttempts[urlString] {
                let delay = delayWithJitter(attempts: attempts)
                let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)

                if timeSinceLastAttempt < delay {
                    #if DEBUG
                    print("NostrService: Skipping reconnect to \(urlString) - backing off (\(attempts) attempts, \(delay - timeSinceLastAttempt)s remaining)")
                    #endif
                    // Schedule retry after backoff delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + (delay - timeSinceLastAttempt)) { [weak self] in
                        guard let self = self else { return }
                        guard self.clients[urlString] != nil else { return }
                        self.fetchNotes(from: [url], until: until, since: since, authors: authors)
                    }
                    continue
                }
            }

            relaysReconnecting.insert(urlString)

            // Close old subscription explicitly before creating a new client
            if let oldSubId = activeSubscriptions[urlString] {
                if let oldClient = clients[urlString] {
                    let closeMsg = ["CLOSE", oldSubId] as [Any]
                    if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                       let closeStr = String(data: closeData, encoding: .utf8) {
                        oldClient.send(text: closeStr)
                    }
                }
                activeSubscriptions.removeValue(forKey: urlString)
            }

            // Disconnect old client before replacing
            clients[urlString]?.disconnect()

            let client = WebSocketClient()
            clients[urlString] = client

            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    guard let self = self else { return }
                    self.updateAggregatedStatus()
                    if state == .connected {
                        // Reset backoff on successful connection
                        self.relayReconnectAttempts[urlString] = 0
                        self.relaysReconnecting.remove(urlString)
                        self.sendRequest(to: client!, url: url, until: until, since: since, authors: authors)
                    } else if state == .error {
                        self.relaysReconnecting.remove(urlString)

                        // Increment backoff counter
                        let attempts = (self.relayReconnectAttempts[urlString] ?? 0) + 1
                        self.relayReconnectAttempts[urlString] = attempts
                        self.relayLastReconnectTime[urlString] = Date()

                        // Check if we've exceeded max attempts - stop hammering
                        if attempts > self.maxReconnectAttempts {
                            #if DEBUG
                            print("NostrService: Max reconnect attempts reached for \(urlString), giving up")
                            #endif
                            // This subscription will never EOSE — release its slot
                            // so a dead relay can't hold `isFetching` true.
                            self.activeSubscriptionCount -= 1
                            if self.activeSubscriptionCount <= 0 {
                                self.isFetching = false
                                self.activeSubscriptionCount = 0
                                self.cancelFetchWatchdog()
                            }
                            return
                        }

                        // Calculate exponential backoff delay with jitter
                        let delay = self.delayWithJitter(attempts: attempts - 1)

                        #if DEBUG
                        print("NostrService: Reconnecting to \(urlString) in \(delay)s (attempt \(attempts)/\(self.maxReconnectAttempts))")
                        #endif

                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self else { return }
                            guard self.clients[urlString] != nil else { return }
                            self.fetchNotes(from: [url], until: until, authors: authors)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            awaiting += 1
        }

        // Commit fetch state once, now that we know how many subscriptions will
        // actually report EOSE, and arm the watchdog. If nothing was opened
        // (awaiting == 0) there is nothing to wait for — don't latch isFetching.
        isFetching = awaiting > 0
        activeSubscriptionCount = awaiting
        if awaiting > 0 {
            armFetchWatchdog()
        } else {
            cancelFetchWatchdog()
        }
    }

    /// Arms (or re-arms) the fetch watchdog. If `isFetching` is still true after
    /// the timeout — some subscription never delivered EOSE (unreachable relay or
    /// a socket torn down mid-fetch) — force it off so the Viewer/Relay
    /// "Loading notes…" overlay can never hang. Cancelled on real completion.
    private func armFetchWatchdog() {
        fetchWatchdogTask?.cancel()
        fetchWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s safety net
            guard let self = self, !Task.isCancelled, self.isFetching else { return }
            #if DEBUG
            print("NostrService: fetch watchdog fired — forcing isFetching=false (\(self.activeSubscriptionCount) subscription(s) never EOSE'd)")
            #endif
            self.flushEventBuffer()
            self.activeSubscriptionCount = 0
            self.isFetching = false
            self.eventUpdateSubject.send()
        }
    }

    private func cancelFetchWatchdog() {
        fetchWatchdogTask?.cancel()
        fetchWatchdogTask = nil
    }


    private func sendRequest(to client: WebSocketClient, url: URL, until: Int64? = nil, since: Int64? = nil, authors: [String]? = nil) {
        let urlString = url.absoluteString
        let isHistorical = until != nil

        let context = url.lastPathComponent.isEmpty ? "root" : url.lastPathComponent
        let subscriptionId: String

        if isHistorical {
            // Unique ID for pagination
            subscriptionId = "viewer-\(context)-hist-\(UUID().uuidString.prefix(4))"
        } else {
            // Stable ID for live feed
            subscriptionId = "viewer-\(context)-live"

            // Close previous live subscription if it's different (shouldn't happen with stable names, but safer)
            if let oldId = activeSubscriptions[urlString], oldId != subscriptionId {
                let closeMsg = ["CLOSE", oldId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    client.send(text: closeStr)
                }
            }
            activeSubscriptions[urlString] = subscriptionId
        }

        // Split note kinds from engagement/metadata kinds. The relay returns the
        // newest N events PER FILTER regardless of kind, so a single all-kinds
        // filter lets a high volume of reactions/zaps crowd actual notes out of
        // the window on cold start (notes are cached but never loaded into memory).
        // Giving notes their own filter guarantees they load independent of how
        // many reactions/zaps share the window — same rationale as bounding
        // long-form bodies separately.
        let noteKinds = [1, 6, 30023]
        let metaKinds = [0, 3, 4, 7, 1063, 9735, 10000, 10063]
        let noteLimit = isHistorical ? 100 : 400
        let metaLimit = isHistorical ? 100 : 200

        func makeFilter(kinds: [Int], limit: Int, mentionsOwner: String?) -> [String: Any] {
            var f: [String: Any] = ["limit": limit, "kinds": kinds]
            if let until = until { f["until"] = until }
            if let since = since { f["since"] = since }
            // Author scoping applies to the owner/whitelist feed, not the mentions feed.
            if mentionsOwner == nil, let authors = authors, !authors.isEmpty {
                f["authors"] = authors
            }
            if let owner = mentionsOwner {
                f["#p"] = [owner]
            }
            return f
        }

        // Owner/whitelist feed: notes get a generous limit, engagement/metadata its own.
        var filters: [[String: Any]] = [
            makeFilter(kinds: noteKinds, limit: noteLimit, mentionsOwner: nil),
            makeFilter(kinds: metaKinds, limit: metaLimit, mentionsOwner: nil),
        ]

        // CRITICAL: Always subscribe to mentions (#p) of the owner so "tagged notes"
        // from people we don't follow still show up in the viewer. Split the same way
        // so replies aren't starved by reactions/zaps tagging the owner.
        let ownerHex = self.activeHexPubkey
        if !ownerHex.isEmpty {
            filters.append(makeFilter(kinds: noteKinds, limit: noteLimit, mentionsOwner: ownerHex))
            filters.append(makeFilter(kinds: metaKinds, limit: metaLimit, mentionsOwner: ownerHex))
        }

        let req = ["REQ", subscriptionId] + filters
        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            #if DEBUG
            print("NostrService: Sending REQ (\(subscriptionId)) with \(filters.count) filters to \(url.absoluteString)")
            #endif
            client.send(text: reqString)
        }
    }


    private func updateAggregatedStatus() {
        let states = clients.values.map { $0.connectionState }
        if states.contains(.connected) {
            // Upgrading to green is immediate; cancel any pending downgrade
            statusDowngradeTask?.cancel()
            statusDowngradeTask = nil
            connectionStatus = "Connected"
            connectionColor = "green"
        } else {
            // Downgrade from green is debounced to avoid flicker during brief reconnects
            let wasGreen = connectionColor == "green"
            let newStatus: String
            let newColor: String
            if states.contains(.connecting) {
                newStatus = "Connecting..."
                newColor = "yellow"
            } else if states.contains(.error) {
                newStatus = "Connection Error"
                newColor = "red"
            } else {
                newStatus = "Disconnected"
                newColor = "gray"
            }

            if wasGreen && newColor == "yellow" {
                // Debounce: wait before showing yellow so brief reconnects don't flicker
                if statusDowngradeTask == nil {
                    statusDowngradeTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        // Re-check state after delay
                        let currentStates = self.clients.values.map { $0.connectionState }
                        if !currentStates.contains(.connected) {
                            self.connectionStatus = newStatus
                            self.connectionColor = newColor
                        }
                        self.statusDowngradeTask = nil
                    }
                }
            } else {
                statusDowngradeTask?.cancel()
                statusDowngradeTask = nil
                connectionStatus = newStatus
                connectionColor = newColor
            }
        }
    }

    private func processMessage(_ message: String, from urlString: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let type = json[0] as? String else {
            return
        }

        if type == "EOSE", let subId = json[1] as? String {
            // Close historical subscriptions immediately after EOSE
            if subId.contains("-hist-") {
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8),
                   let client = clients[urlString] {
                    client.send(text: closeStr)
                    #if DEBUG
                    print("NostrService: Closed historical subscription \(subId)")
                    #endif
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Flush any buffered events before marking EOSE complete
                self.flushEventBuffer()
                self.activeSubscriptionCount -= 1
                if self.activeSubscriptionCount <= 0 {
                    self.isFetching = false
                    self.activeSubscriptionCount = 0
                    self.cancelFetchWatchdog()
                }
                self.events.sort(by: { $0.created_at > $1.created_at })
                self.eventUpdateSubject.send()
            }
        }

        if type != "EVENT" { return }

        guard json.count >= 3 else { return }

        if let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            // Inject feed-relevant events from external relays into the local relay
            // so they persist beyond the current session (e.g. mac relay events).
            if let sourceURL = URL(string: urlString), !isLocalRelay(sourceURL) {
                FeedService.shared.injectExternalEvent(eventDict, eventId: event.id)
            }

            // Early dedup for replaceable events (kind 3 contact lists, etc.)
            // that flood on every re-subscription. Skip before any expensive processing.
            let replaceableKinds: Set<Int> = [3]
            if replaceableKinds.contains(event.kind) && hasSeen(event.id) {
                return
            }

            if event.kind == 0 {
                let content = event.content
                let pubkey = event.pubkey
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let result = ProfileRepository.parseMetadataContent(content, pubkey: pubkey, existingProfile: self.profiles[pubkey]),
                       result.changed {
                        self.profiles[pubkey] = result.profile
                        self.profilesInFlight.remove(pubkey)
                        self.saveProfilesThrottled()
                        self.eventUpdateSubject.send()
                        self.noteProfileUpdated(pubkey)
                    }
                }
                return
            }

            if event.kind == 10002 {
                let parsed = ProfileRepository.parseRelayListTags(event.tags)
                let pubkey = event.pubkey
                let createdAt = event.created_at
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.relaysInFlight.remove(pubkey)
                    if let known = self.relayListCreatedAt[pubkey], createdAt < known { return }
                    self.relayListCreatedAt[pubkey] = createdAt
                    if !parsed.inbox.isEmpty { self.relayLists[pubkey] = parsed.inbox }
                    if !parsed.write.isEmpty { self.outboxRelays[pubkey] = parsed.write }
                    self.saveProfilesThrottled()
                }
                return
            }

            if event.kind == 10050 {
                let dmRelays = ProfileRepository.parseDMRelayListTags(event.tags)
                let pubkey = event.pubkey
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if !dmRelays.isEmpty { self.dmRelayLists[pubkey] = dmRelays }
                    self.dmRelaysInFlight.remove(pubkey)
                    self.saveProfilesThrottled()
                }
                return
            }

            if event.kind == 10063 {
                let servers = ProfileRepository.parseServerListTags(event.tags)
                let pubkey = event.pubkey
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if !servers.isEmpty { self.serverLists[pubkey] = servers }
                    self.saveProfilesThrottled()
                }
                return
            }

            if event.kind == 10000 {
                let blockedHexKeys = ProfileRepository.parseMuteListPTags(event.tags)
                let allNpubs = ConfigService.shared.allAccountNpubs
                if let matchingNpub = allNpubs.first(where: { npub in
                    Bech32.decode(npub)?.hexString == event.pubkey
                }) {
                    let blockedNpubs = ProfileRepository.hexKeysToNpubs(blockedHexKeys)
                    let eventTimestamp = event.created_at
                    DispatchQueue.main.async {
                        let currentBlocks = ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] ?? []
                        let lastSync = ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] ?? 0

                        if eventTimestamp >= lastSync && Set(currentBlocks) != Set(blockedNpubs) {
                            ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] = blockedNpubs
                            ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] = eventTimestamp
                            if matchingNpub == ConfigService.shared.config.ownerNpub {
                                ConfigService.shared.config.blacklistedNpubs = blockedNpubs
                            }
                            ConfigService.shared.save()
                            #if DEBUG
                            print("NostrService: Synced \(blockedNpubs.count) blocks from Kind 10000 for \(matchingNpub.prefix(8))")
                            #endif
                            NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
                        }
                    }
                }
                return
            }

            if !markSeen(event.id) { return }

            var items: [MediaItem] = []

            if event.kind == 1063 {
                // Parse KIND 1063 — NIP-94 file metadata with "url" and "m" (mime) tags
                if let urlTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "url" }),
                   let url = URL(string: urlTag[1]) {
                    let mimeTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "m" })?[1]
                    let mime = mimeTag ?? Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    items.append(MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime))
                }
            } else {
                let urls = extractMediaURLs(from: event.content)
                items = urls.map { url in
                    let mime = Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime)
                }
            }

            // Buffer event instead of dispatching to main thread per-event
            bufferLock.lock()
            eventBuffer.append((event, items))
            bufferLock.unlock()
            scheduleBufferFlush()
        }
    }


    // MARK: - Seen-event dedup (thread-safe)

    /// Atomically records `id`: returns true if it was NOT seen before (and
    /// inserts it), false if already seen. Also trims the set when it grows
    /// large. Replaces the racy contains()/insert() pairs that previously ran on
    /// both the background processing queue and the main thread.
    private func markSeen(_ id: String) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        if seenEventIds.contains(id) { return false }
        seenEventIds.insert(id)
        // Prevent unbounded memory growth — trim oldest entries when large.
        if seenEventIds.count > 50_000 {
            let excess = seenEventIds.count - 40_000
            seenEventIds = Set(seenEventIds.dropFirst(excess))
        }
        return true
    }

    /// Thread-safe membership check.
    private func hasSeen(_ id: String) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        return seenEventIds.contains(id)
    }

    /// Thread-safe clear (used on account switch).
    private func clearSeen() {
        seenLock.lock()
        defer { seenLock.unlock() }
        seenEventIds.removeAll()
    }

    // MARK: - Batched Event Flushing

    private func scheduleBufferFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bufferFlushTimer == nil else { return }
            self.bufferFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.flushEventBuffer()
                }
            }
        }
    }

    private func flushEventBuffer() {
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil

        bufferLock.lock()
        let batch = eventBuffer
        eventBuffer.removeAll()
        bufferLock.unlock()

        guard !batch.isEmpty else { return }

        var newEvents: [NostrEvent] = []
        for (event, items) in batch {
            newEvents.append(event)
            if !items.isEmpty {
                noteMedia.append(contentsOf: items)
            }
        }

        // Efficiently merge and sort
        events.append(contentsOf: newEvents)

        // Only sort if we have a significant number of new events or the list is out of order
        // This is a trade-off: keep it snappy vs perfectly sorted at all times.
        if events.count > 1 {
            events.sort(by: { $0.created_at > $1.created_at })
        }

        if events.count > Self.maxEvents {
            events = Array(events.prefix(Self.maxEvents))
        }
        // Bound the heavy long-form bodies independently of the overall ceiling. `events`
        // is sorted newest→oldest, so this keeps the newest `maxLongFormEvents` articles
        // in full and drops older ones, without touching the lightweight bulk.
        let longFormCount = events.reduce(0) { $0 + ($1.kind == 30023 ? 1 : 0) }
        if longFormCount > Self.maxLongFormEvents {
            var kept = 0
            events = events.filter { event in
                guard event.kind == 30023 else { return true }
                kept += 1
                return kept <= Self.maxLongFormEvents
            }
        }
        if noteMedia.count > Self.maxNoteMedia {
            noteMedia.sort(by: { $0.dateAdded > $1.dateAdded })
            noteMedia = Array(noteMedia.prefix(Self.maxNoteMedia))
        }
        eventUpdateSubject.send()
    }

    /// Inject an externally-received event into the shared events array.
    /// Used by FeedService to forward zap receipts (Kind 9735) so the Viewer can display them.
    func injectEvent(_ event: NostrEvent) {
        guard markSeen(event.id) else { return }
        bufferLock.lock()
        eventBuffer.append((event, []))
        bufferLock.unlock()
        scheduleBufferFlush()
    }

    // MARK: - Quoted Events

    /// Identifiers already requested by `fetchQuotedEvent`, so a row that keeps
    /// reappearing does not re-request the same missing note.
    private var quotedEventsInFlight = Set<String>()

    /// The event a quote reference points at, if this relay already holds it.
    /// Accepts either a 64-hex event id or an `"naddr:<kind>:<pubkey>:<d-tag>"`
    /// coordinate, matching `FeedService.findNote(id:)`.
    func storedEvent(matching identifier: String) -> NostrEvent? {
        // `events` is sorted newest first, so for an addressable event the first
        // match is the current one.
        let matcher = QuoteReference.matcher(for: identifier)
        return events.first {
            matcher.matches(id: $0.id, kind: $0.kind, pubkey: $0.pubkey, tags: $0.tags)
        }
    }

    /// Requests a quoted event this relay does not hold, from the local relay and
    /// the configured feed relays. Safe to call from a view's `onAppear`: each
    /// identifier is requested once per session.
    func fetchQuotedEvent(_ identifier: String) {
        guard storedEvent(matching: identifier) == nil,
              !quotedEventsInFlight.contains(identifier) else { return }
        quotedEventsInFlight.insert(identifier)

        let config = ConfigService.shared.config
        var urls = [config.nostrURL].compactMap { URL(string: $0) }
        let externals = config.activeFeedRelays.isEmpty
            ? ["wss://relay.primal.net", "wss://nos.lol"]
            : config.activeFeedRelays
        urls.append(contentsOf: externals.compactMap { URL(string: $0) })
        guard !urls.isEmpty else { return }

        if let (kind, pubkey, dTag) = QuoteReference.parseCoordinate(identifier) {
            fetchAddressableEvent(kind: kind, pubkey: pubkey, dTag: dTag, from: urls)
        } else {
            fetchNotesByIds([identifier], from: urls)
        }
    }

    /// Fetches an addressable (NIP-33) event by its coordinate. `fetchNotesByIds`
    /// cannot serve these — a coordinate is not an event id, so an `ids` filter
    /// would match nothing.
    private func fetchAddressableEvent(kind: Int, pubkey: String, dTag: String, from relayURLs: [URL]) {
        let filter: [String: Any] = ["kinds": [kind], "authors": [pubkey], "#d": [dTag], "limit": 1]

        for url in relayURLs {
            let urlString = url.absoluteString
            if isLocalRelay(url) && !isLocalRelayReady { continue }

            let subId = "addr-\(UUID().uuidString.prefix(6))"
            let req = ["REQ", subId, filter] as [Any]
            guard let data = try? JSONSerialization.data(withJSONObject: req),
                  let reqString = String(data: data, encoding: .utf8) else { continue }

            if let existing = clients[urlString], existing.connectionState == .connected {
                existing.send(text: reqString)
                continue
            }

            let client = WebSocketClient()
            client.isTemporary = true
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    guard let client = client else { return }
                    client.send(text: reqString)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { client.disconnect() }
                }
                .store(in: &cancellables)
            client.connect(url: url)
        }
    }

    /// Fetch specific events by their IDs from the given relays.
    /// Results are merged into the shared `events` array via the normal processing pipeline.
    func fetchNotesByIds(_ ids: [String], from relayURLs: [URL]) {
        guard !ids.isEmpty else { return }

        let filter: [String: Any] = ["ids": ids]

        for url in relayURLs {
            let urlString = url.absoluteString
            if isLocalRelay(url) && !isLocalRelayReady { continue }

            // Reuse existing connected client if available
            if let existing = clients[urlString], existing.connectionState == .connected {
                let subId = "byid-\(UUID().uuidString.prefix(6))"
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let str = String(data: data, encoding: .utf8) {
                    existing.send(text: str)
                }
                continue
            }

            let client = WebSocketClient()
            client.isTemporary = true
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            let safeFilter = UncheckedSendable(value: filter)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    guard let client = client else { return }
                    let subId = "byid-\(UUID().uuidString.prefix(6))"
                    let req = ["REQ", subId, safeFilter.value] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    /// Fetches zap receipts (kind 9735) with a larger limit to cover more history.
    func fetchZapReceipts(from relayURLs: [URL], limit: Int = 1000) {
        let filter: [String: Any] = ["kinds": [9735], "limit": limit]

        for url in relayURLs {
            let urlString = url.absoluteString
            if isLocalRelay(url) && !isLocalRelayReady { continue }

            if let existing = clients[urlString], existing.connectionState == .connected {
                let subId = "zaps-\(UUID().uuidString.prefix(6))"
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let str = String(data: data, encoding: .utf8) {
                    existing.send(text: str)
                }
                continue
            }

            let client = WebSocketClient()
            client.isTemporary = true
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            let safeFilter = UncheckedSendable(value: filter)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    guard let client = client else { return }
                    let subId = "zaps-\(UUID().uuidString.prefix(6))"
                    let req = ["REQ", subId, safeFilter.value] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    func fetchCount(from relayURLs: [URL], filter: [String: Any] = [:]) async -> Int? {
        #if DEBUG
        print("NostrService: Starting aggregate fetchCount for \(relayURLs.count) relays")
        #endif
        var totalCount: Int? = nil
        var responsesReceived = 0

        let safeFilter = UncheckedSendable(value: filter)

        await withTaskGroup(of: Int?.self) { group in
            for url in relayURLs {
                group.addTask {
                    let filter = safeFilter.value
                    let urlString = url.absoluteString
                    let relayTag = url.lastPathComponent.isEmpty ? "outbox" : url.lastPathComponent

                    #if DEBUG
                    print("NostrService [\(relayTag)]: Task started")
                    #endif

                    let (client, isNew) = await MainActor.run { () -> (WebSocketClient?, Bool) in
                        if let existing = self.clients[urlString] {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Using existing client")
                            #endif
                            return (existing, false)
                        } else {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Creating new client")
                            #endif
                            let newClient = WebSocketClient()
                            newClient.isTemporary = true
                            return (newClient, true)
                        }
                    }

                    guard let client = client else {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Failed to get client")
                        #endif
                        return nil
                    }

                    // 1. Wait for connection if needed
                    if client.connectionState != .connected {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Not connected. Connecting now...")
                        #endif
                        client.connect(url: url)

                        var cancellable: AnyCancellable?
                        let didConnect = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                            var hasResumed = false

                            cancellable = client.$connectionState
                                .first(where: { $0 == .connected || $0 == .error })
                                .timeout(.seconds(5), scheduler: DispatchQueue.main)
                                .sink { completion in
                                    if !hasResumed {
                                        hasResumed = true
                                        if case .failure = completion {
                                            #if DEBUG
                                            print("NostrService [\(relayTag)]: Connection timeout")
                                            #endif
                                        }
                                        continuation.resume(returning: false)
                                    }
                                } receiveValue: { state in
                                    if !hasResumed {
                                        hasResumed = true
                                        #if DEBUG
                                        print("NostrService [\(relayTag)]: Connection state reached: \(state)")
                                        #endif
                                        continuation.resume(returning: state == .connected)
                                    }
                                }
                        }
                        _ = cancellable // Hold it until await finishes

                        if !didConnect {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Failed to connect during fetchCount")
                            #endif
                            if isNew { await MainActor.run { client.disconnect() } }
                            return nil
                        }
                    }

                    // 2. Send COUNT and wait for response
                    let subscriptionId = "count-\(UUID().uuidString.prefix(6))"
                    #if DEBUG
                    print("NostrService [\(relayTag)]: Sending COUNT with subId: \(subscriptionId)")
                    #endif

                    var messageCancellable: AnyCancellable?
                    let countResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                        var hasResumed = false

                        messageCancellable = client.messageSubject
                            .timeout(.seconds(10), scheduler: DispatchQueue.main)
                            .sink { completion in
                                if !hasResumed {
                                    hasResumed = true
                                    #if DEBUG
                                    print("NostrService [\(relayTag)]: COUNT response timeout or completion")
                                    #endif
                                    continuation.resume(returning: nil)
                                }
                            } receiveValue: { msg in
                                guard let data = msg.data(using: .utf8),
                                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                      json.count >= 3,
                                      let type = json[0] as? String,
                                      let subId = json[1] as? String,
                                      subId == subscriptionId else {
                                    return
                                }

                                if type == "COUNT" {
                                    if let payload = json[2] as? [String: Any],
                                       let rawCount = payload["count"] {
                                        let extractedCount: Int
                                        if let intVal = rawCount as? Int {
                                            extractedCount = intVal
                                        } else if let doubleVal = rawCount as? Double {
                                            extractedCount = Int(doubleVal)
                                        } else if let numberVal = rawCount as? NSNumber {
                                            extractedCount = numberVal.intValue
                                        } else if let stringVal = rawCount as? String, let intVal = Int(stringVal) {
                                            extractedCount = intVal
                                        } else {
                                            extractedCount = 0
                                        }
                                        
                                        if !hasResumed {
                                            hasResumed = true
                                            #if DEBUG
                                            print("NostrService [\(relayTag)]: Received COUNT, count: \(extractedCount)")
                                            #endif
                                            continuation.resume(returning: extractedCount)
                                        }
                                    }
                                }
                            }

                        // Send the actual COUNT request
                        let req = ["COUNT", subscriptionId, filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqString = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqString)
                        } else {
                            if !hasResumed {
                                hasResumed = true
                                continuation.resume(returning: nil)
                            }
                        }
                    }
                    _ = messageCancellable // Hold it until await finishes

                    if isNew {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Disconnecting temporary client")
                        #endif
                        await MainActor.run { client.disconnect() }
                    }

                    #if DEBUG
                    print("NostrService [\(relayTag)]: Returning count: \(String(describing: countResult))")
                    #endif
                    return countResult
                }
            }

            for await count in group {
                if let count = count {
                     totalCount = (totalCount ?? 0) + count
                     responsesReceived += 1
                }
            }
        }

        // Only return an aggregate count when ALL endpoints responded.
        // Partial responses cause wild fluctuations (e.g. 3 vs 21,000)
        // because failed endpoints are silently skipped.
        guard responsesReceived == relayURLs.count else {
            #if DEBUG
            print("NostrService: Only \(responsesReceived)/\(relayURLs.count) endpoints responded — returning nil to avoid partial count")
            #endif
            return nil
        }

        #if DEBUG
        print("NostrService: Final aggregated count: \(String(describing: totalCount))")
        #endif
        return totalCount
    }

    static func mimeFromExtension(_ url: URL) -> String? {
        EventPublisher.mimeFromExtension(url)
    }

    nonisolated static func mediaTypeFromMime(_ mime: String?, url: URL) -> MediaItem.MediaType {
        EventPublisher.mediaTypeFromMime(mime, url: url)
    }

    /// Sniff the first 64 bytes of a remote URL via HTTP Range request to detect mime type.
    /// Returns (resolvedMime, mediaType) or nil if the request fails.
    nonisolated static func sniffRemoteMime(url: URL, rpm: RelayProcessManager) -> (mime: String, type: MediaItem.MediaType)? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        request.timeoutInterval = 5

        let semaphore = DispatchSemaphore(value: 0)
        var resultMime: String?

        // Use a session that ignores TLS errors for localhost
        let session = TLSSkipSession.shared
        let task = session.dataTask(with: request) { data, _, _ in
            if let data = data, data.count >= 4 {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? data.write(to: tempURL)
                let detected = rpm.detectMimeFromBytes(for: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                if detected != "application/octet-stream" {
                    resultMime = detected
                }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 6)

        guard let mime = resultMime else { return nil }
        let type = mediaTypeFromMime(mime, url: url)
        return (mime, type)
    }

    func extractMediaURLs(from content: String) -> [URL] {
        guard let regex = SupportedMediaFormats.mediaURLRegex else { return [] }
        let nsString = content as NSString
        let results = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsString.length))

        var urls: [URL] = []
        for result in results {
            let urlString = nsString.substring(with: result.range)
            if let url = URL(string: urlString) {
                urls.append(url)
            }
        }

        return urls.map { url in
            var finalURL = url

            // Normalize potential local/development URLs to use HTTP instead of HTTPS
            // We check for localhost, 127.0.0.1, and any URL that matches the current relayURL if it's local
            let isKnownLocal = finalURL.host == "localhost" ||
                               finalURL.host == "127.0.0.1" ||
                               ConfigService.shared.config.isLocal

            if finalURL.scheme == "https" && isKnownLocal {
                var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)
                components?.scheme = "http"
                if let normalizedURL = components?.url {
                    finalURL = normalizedURL
                }
            }
            return finalURL
        }
    }
}

// MARK: - Local Relay Search Session

/// Walks every local relay route to exhaustion for one query.
///
/// One socket per route, two paged subscriptions per socket (kind 1 notes and
/// kind 0 profiles). A page finishes on its own EOSE, and the whole search
/// finishes as soon as the last subscription is done — the timeout is only
/// there for a socket that never answers.
final class LocalRelaySearchSession {
    /// Fallback for a route that never connects or never EOSEs. Not the normal
    /// completion path: on-box LMDB answers a page in milliseconds.
    static let timeout: TimeInterval = 6.0

    private struct Stream {
        let routeIndex: Int
        let kind: Int
        var page: Int
    }

    private let queue = DispatchQueue(label: "com.haven.local-relay-search")
    private let collector: LocalRelaySearchCollector
    private let routes: [URL]
    private let onFinish: (GlobalSearchResults) -> Void

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var streams: [String: Stream] = [:]
    /// In-flight subscriptions per route. A route with no entry has not opened
    /// its streams yet — which is not the same as being finished, and treating
    /// the two alike would end the search as soon as the FIRST route drained.
    private var activeByRoute: [Int: Int] = [:]
    private var doneRoutes = Set<Int>()
    private var didFinish = false
    private var didStart = false

    init(matcher: LocalSearchMatcher,
         routes: [URL],
         onFinish: @escaping (GlobalSearchResults) -> Void) {
        self.collector = LocalRelaySearchCollector(matcher: matcher)
        self.routes = routes
        self.onFinish = onFinish
    }

    /// Folds in profiles the app already holds; see the collector's note on why
    /// the relay cannot answer a username search on its own.
    func addCachedProfiles(_ cached: [String: FeedProfile]) {
        collector.addCachedProfiles(cached)
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.didStart else { return }
            self.didStart = true

            guard !self.routes.isEmpty else {
                self.finish()
                return
            }

            for (index, url) in self.routes.enumerated() {
                let client = WebSocketClient()
                client.isTemporary = true
                self.clients.append(client)

                client.messageSubject
                    .receive(on: self.queue)
                    .sink { [weak self] message in self?.handle(message: message) }
                    .store(in: &self.cancellables)

                client.$connectionState
                    .receive(on: self.queue)
                    .sink { [weak self] state in
                        guard let self = self else { return }
                        switch state {
                        case .connected:
                            self.openStreams(routeIndex: index)
                        case .error:
                            // A route that cannot be reached must not hold the
                            // whole search open until the timeout.
                            self.failStreams(routeIndex: index)
                        case .disconnected:
                            // `connectionState` publishes `.disconnected` as its
                            // initial value, before `connect(url:)` is even
                            // called — only a drop AFTER the streams opened is
                            // a failure.
                            if self.activeByRoute[index] != nil {
                                self.failStreams(routeIndex: index)
                            }
                        case .connecting:
                            break
                        }
                    }
                    .store(in: &self.cancellables)

                client.connect(url: url)
            }
        }

        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.finish()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.didFinish = true
            self.teardown()
        }
    }

    // MARK: Private

    /// Opens one paged subscription per kind on a route that just connected.
    private func openStreams(routeIndex: Int) {
        guard !didFinish, !doneRoutes.contains(routeIndex) else { return }
        // Reconnects deliver `.connected` more than once; only open a route's
        // streams the first time.
        guard activeByRoute[routeIndex] == nil else { return }
        let kinds = [1, 0]
        activeByRoute[routeIndex] = kinds.count
        for kind in kinds {
            send(stream: Stream(routeIndex: routeIndex, kind: kind, page: 1), until: nil)
        }
    }

    private func send(stream: Stream, until: Int64?) {
        guard routes.indices.contains(stream.routeIndex),
              clients.indices.contains(stream.routeIndex) else { return }
        let subId = "lsearch-\(UUID().uuidString.prefix(8))"
        streams[subId] = stream

        var filter: [String: Any] = [
            "kinds": [stream.kind],
            "limit": LocalRelaySearchPlan.pageLimit
        ]
        if let until = until { filter["until"] = until }

        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            clients[stream.routeIndex].send(text: str)
        }
    }

    private func handle(message: String) {
        guard !didFinish else { return }
        switch collector.ingest(message: message) {
        case .ignored, .event:
            return
        case .eose(let subId):
            guard let stream = streams.removeValue(forKey: subId) else { return }
            close(subId: subId, routeIndex: stream.routeIndex)

            let stats = collector.takeStats(for: subId)
            switch LocalRelaySearchPlan.step(received: stats.received,
                                             newIds: stats.newIds,
                                             oldestCreatedAt: stats.oldestCreatedAt,
                                             pagesFetched: stream.page) {
            case .done:
                let remaining = (activeByRoute[stream.routeIndex] ?? 1) - 1
                activeByRoute[stream.routeIndex] = remaining
                if remaining <= 0 { markDone(routeIndex: stream.routeIndex) }
            case .next(let until):
                var next = stream
                next.page += 1
                send(stream: next, until: until)
            }
        }
    }

    private func close(subId: String, routeIndex: Int) {
        guard clients.indices.contains(routeIndex) else { return }
        let msg = ["CLOSE", subId] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            clients[routeIndex].send(text: str)
        }
    }

    /// A route's socket died: drop its in-flight streams so the remaining
    /// routes can still complete the search.
    private func failStreams(routeIndex: Int) {
        guard !didFinish, !doneRoutes.contains(routeIndex) else { return }
        for (subId, stream) in streams where stream.routeIndex == routeIndex {
            streams.removeValue(forKey: subId)
        }
        activeByRoute[routeIndex] = 0
        markDone(routeIndex: routeIndex)
    }

    /// A route has nothing left in flight. The search ends only when EVERY
    /// route is done — a fast route draining first must not cut off a slower
    /// one that has not even opened its subscriptions yet.
    private func markDone(routeIndex: Int) {
        doneRoutes.insert(routeIndex)
        if doneRoutes.count >= routes.count { finish() }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        let results = collector.snapshot()
        teardown()
        onFinish(results)
    }

    private func teardown() {
        for client in clients { client.disconnect() }
        clients.removeAll()
        cancellables.removeAll()
        streams.removeAll()
    }
}

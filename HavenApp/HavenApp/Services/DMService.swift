import Foundation
import Combine

// MARK: - DMService

@MainActor
class DMService: ObservableObject {
    static let shared = DMService()

    @Published var conversations: [DMConversation] = []
    @Published var isLoading: Bool = false
    /// Messages that arrived but the signer could not open yet (remote signer
    /// offline, slow or refused). Shown on the Messages screen, retried on
    /// their own, and again on every refresh.
    @Published var waitingForSignerCount = 0

    /// The inbox as shown: conversations with a blocked person are hidden.
    /// They stay in `conversations` (and on disk), so unblocking brings them back.
    var visibleConversations: [DMConversation] {
        BlockedPeople.visibleConversations(conversations, blocked: ConfigService.shared.activeAccountBlockedHexPubkeys) { $0.id }
    }

    var totalUnreadCount: Int {
        visibleConversations.reduce(0) { $0 + $1.unreadCount }
    }

    var inboxClient: WebSocketClient?       // /chat (NIP-17 gift wraps)
    var nip04Client: WebSocketClient?        // /inbox (NIP-04 legacy DMs)
    var externalClients: [WebSocketClient] = [] // temporary external relay clients
    var cancellables = Set<AnyCancellable>()
    /// Subscriptions tied to the current chat/NIP-04 clients.
    /// Cancelled on reconnect to prevent stale clients from firing events.
    var connectionCancellables = Set<AnyCancellable>()
    var seenGiftWrapIds = Set<String>()
    private let maxSeenGiftWrapIds = 10_000

    /// Gift wraps that opened to something that is not a chat message (or
    /// could never be opened). Saved per account, so a launch does not send
    /// them to a remote signer again — with NIP-46 each one costs the user's
    /// signer two NIP-44 decrypts, every launch, forever.
    var unreadableGiftWrapIds = Set<String>()
    let maxUnreadableGiftWrapIds = 5_000

    /// Gift wraps the signer did not open, by id, waiting for another try.
    /// A failure used to leave the id in `seenGiftWrapIds`, so the wrap was
    /// skipped for the rest of the session: the relay's notification went out,
    /// and the message only appeared after the app was relaunched.
    var signerWaiting: [String: NostrEvent] = [:]
    var signerRetryTask: Task<Void, Never>?
    var signerRetryAttempt = 0

    /// /inbox (NIP-04 and the gift wraps stored there) reconnects on its own,
    /// like /chat. Before, it came back only when the app returned to the
    /// foreground, so with the app open new DMs stopped reaching the inbox
    /// while the relay still announced them.
    var inboxReconnectTask: Task<Void, Never>?
    var inboxReconnectAttempt = 0

    /// Gift wraps waiting to be opened. Drained newest first by at most
    /// `maxGiftWrapWorkers` at a time: the backlog used to start one Task per
    /// wrap at once, which flooded a remote signer with decrypt requests.
    var pendingGiftWraps: [NostrEvent] = []
    var giftWrapWorkers = 0
    let maxGiftWrapWorkers = 1

    /// Rebuild the dedup set from retained conversation messages once it
    /// outgrows the cap — it otherwise accumulates an entry for every gift
    /// wrap ever observed across a long-running session.
    func trimSeenGiftWrapIdsIfNeeded() {
        guard seenGiftWrapIds.count > maxSeenGiftWrapIds else { return }
        seenGiftWrapIds = Set(conversations.flatMap { $0.messages.map { $0.id } })
            .union(unreadableGiftWrapIds)
    }
    var dmUpdateSubject = PassthroughSubject<Void, Never>()
    let processingQueue = DispatchQueue(label: "com.haven.dm-processing", qos: .userInitiated)
    var pendingAuthChallenge: String?
    var isAuthenticated = false
    var loadedAccountPubkey: String = ""
    var switchGeneration: UInt64 = 0 // incremented on each account switch to invalidate stale callbacks

    // Watch-only (local signing with no usable key) can neither decrypt NIP-04
    // DMs nor sign NIP-42 AUTH. Without gating, a catch-up batch logs one
    // identical "no key" error per DM and every AUTH challenge logs a failure.
    // These latch the notice to once per incapable streak; reset on account switch.
    var warnedNIP04Unavailable = false
    var warnedAuthUnavailable = false

    /// Tracks event IDs already injected into the local relay to prevent duplicate writes.
    var injectedDmIds = Set<String>()
    let maxInjectedDmIds = 5_000

    /// Persisted timestamp for efficient DM catch-up from external relays.
    private let lastExternalFetchKey = "com.haven.dm.lastExternalFetchTimestamp"
    var lastExternalFetchTimestamp: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: lastExternalFetchKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastExternalFetchKey) }
    }

    private init() {
        loadedAccountPubkey = NostrService.shared.activeHexPubkey
        setupThrottling()
        loadConversations()

        // React to account switches only (not every config save). Keyed on the
        // resolved hex key, not `activeAccountNpub`: a new account finishes setup
        // as the owner with `activeAccountNpub` still "", so an npub-keyed sink
        // never fired, this service kept the empty key it read while the setup
        // wizard was on screen, and every send failed with "No active account
        // loaded" until the app was relaunched.
        ConfigService.shared.$activeAccountHexPubkey
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAccountSwitch()
            }
            .store(in: &cancellables)

        // A block or unblock changes what the inbox shows and the unread badge.
        NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Auto-connect when relay becomes available
        RelayProcessManager.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                if state == .running && self.inboxClient == nil {
                    self.startListening()
                } else if state == .idle {
                    self.chatReconnectTask?.cancel()
                    self.chatReconnectTask = nil
                    self.chatReconnectAttempt = 0
                    self.connectionCancellables.removeAll()
                    self.inboxClient?.disconnect()
                    self.inboxClient = nil
                    self.nip04Client?.disconnect()
                    self.nip04Client = nil
                }
            }
            .store(in: &cancellables)
    }

    /// The conversation whose thread is on screen, so a notification for a
    /// message already in front of the user can stay quiet.
    var visibleConversation: String?

    /// Ids of the self-copy wraps this device sent. Every DM you send also
    /// wraps a copy to yourself; this is how its notification is recognised
    /// without decrypting it (a NIP-46 signer may not answer in time).
    var sentSelfWrapIds = Set<String>()

    /// One-time catch-up, per account, of your own sent copies stranded on
    /// your general (kind 10002) relays. Before the DM inbox list, a sent
    /// copy could go to those relays when your 10002 was found before your
    /// 10050, and no device reads DMs there. The regular fetch only reaches
    /// ~2 days back (gift wraps are backdated up to 2 days), so older copies
    /// are never found by it. This asks, with no time window, your newest
    /// published 10002 relays — fetched fresh, the cache can be long out of
    /// date — plus the cached ones and your DM inbox list. Marked done only
    /// after a fresh 10002 lookup answered and every relay was given its
    /// chance, so a launch without network tries again next time.
    var backfillRunning = false

    /// Shared injection clients for writing fetched DMs into the local relay.
    /// Lazily connected and reused across a batch fetch to avoid per-event connections.
    var chatInjectionClient: WebSocketClient?
    var inboxInjectionClient: WebSocketClient?
    /// Pending events queued while the injection client is still connecting.
    var pendingChatInjections: [[String: Any]] = []
    var pendingInboxInjections: [[String: Any]] = []
    static let maxSignerRetries = 8

    // MARK: - /chat auto-reconnect

    /// Nothing used to redial a dead /chat socket: DMs stopped arriving until
    /// the app was next foregrounded or the relay restarted. Retry with
    /// backoff 1, 2, 4 … 60 s while the relay is running. In the background
    /// iOS suspends us anyway, and the foreground refresh() reconnects.
    var chatReconnectTask: Task<Void, Never>?
    var chatReconnectAttempt = 0
}

// MARK: - Array Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

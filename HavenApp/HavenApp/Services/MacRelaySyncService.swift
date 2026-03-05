import Foundation
import Combine

/// Service that syncs missed notes from a remote Mac Haven relay.
///
/// The Mac version of Haven runs 24/7 and accumulates all notes. When the iOS
/// version resumes, this service connects to the Mac relay, requests events
/// since the last sync timestamp, and feeds them into the local relay so
/// the Viewer and Feed have complete data.
@MainActor
class MacRelaySyncService: ObservableObject {
    static let shared = MacRelaySyncService()

    // MARK: - Published State
    @Published var isSyncing = false
    @Published var syncStatus: String = ""
    @Published var lastSyncDate: Date?
    @Published var notesSynced: Int = 0
    
    // MARK: - Private
    private var client: WebSocketClient?
    private var cancellables = Set<AnyCancellable>()
    private var syncedEventIds = Set<String>()
    private var pendingEvents: [[String: Any]] = []
    private let processingQueue = DispatchQueue(label: "com.haven.mac-relay-sync", qos: .userInitiated)
    
    /// UserDefaults key for the last successful sync timestamp
    private let lastSyncKey = "com.haven.macRelay.lastSyncTimestamp"
    
    /// The timestamp of the last successful sync (persisted across app launches)
    var lastSyncTimestamp: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: lastSyncKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastSyncKey) }
    }
    
    // MARK: - Public API
    
    /// Syncs missed notes from the configured Mac relay.
    /// Call this on app foreground or after the local relay finishes booting.
    func syncIfConfigured() {
        let macURL = ConfigService.shared.config.macRelayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !macURL.isEmpty else { return }
        guard !isSyncing else {
            #if DEBUG
            print("MacRelaySyncService: Already syncing, skipping")
            #endif
            return
        }
        
        // Ensure local relay is ready before syncing
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else {
            #if DEBUG
            print("MacRelaySyncService: Local relay not ready, deferring sync")
            #endif
            return
        }
        
        performSync(macRelayURL: macURL)
    }
    /// Force a manual sync (e.g., from a button tap in settings)
    func forceSync() {
        let macURL = ConfigService.shared.config.macRelayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !macURL.isEmpty else {
            syncStatus = "No Mac relay URL configured"
            return
        }
        
        // Cancel any existing sync
        cancelSync()
        
        // For a force sync, we go back 24 hours from the current last sync 
        // to catch anything that might have been missed during clock drifts or filter issues.
        let startTime = max(0, lastSyncTimestamp - (24 * 3600))
        performSync(macRelayURL: macURL, fromTimestamp: startTime)
    }
    
    /// Resets the sync timestamp to zero, forcing the next sync to start from the beginning.
    func resetSync() {
        lastSyncTimestamp = 0
        lastSyncDate = nil
        syncStatus = "Sync timestamp reset"
    }
    
    func cancelSync() {
        client?.disconnect()
        client = nil
        cancellables.removeAll()
        isSyncing = false
    }

    
    // MARK: - Sync Logic
    
    private func performSync(macRelayURL: String, fromTimestamp: Int64? = nil) {
        // Normalize the URL — ensure it has wss:// scheme
        var url = macRelayURL
        if !url.hasPrefix("wss://") && !url.hasPrefix("ws://") {
            url = "wss://" + url
        }
        
        // Connect to root (all events), /inbox, then aggregate
        let endpoints = [url, url + "/inbox"]
        
        isSyncing = true
        notesSynced = 0
        pendingEvents.removeAll()
        syncedEventIds.removeAll()
        syncStatus = "Connecting to Mac relay..."
        
        // Use provided timestamp or 1-hour overlap from last known sync
        let startTime = fromTimestamp ?? max(0, lastSyncTimestamp - 3600)
        
        #if DEBUG
        print("MacRelaySyncService: Starting sync from \(endpoints) since timestamp \(startTime) (original last sync: \(lastSyncTimestamp))")
        #endif
        
        syncFromEndpoints(endpoints, index: 0, since: startTime)
    }
    
    private func syncFromEndpoints(_ endpoints: [String], index: Int, since: Int64) {
        guard index < endpoints.count else {
            // All endpoints done — flush to local relay
            finishSync()
            return
        }
        
        let endpoint = endpoints[index]
        guard let url = URL(string: endpoint) else {
            syncFromEndpoints(endpoints, index: index + 1, since: since)
            return
        }
        
        let wsClient = WebSocketClient()
        wsClient.isTemporary = true
        self.client = wsClient
        
        let subId = "mac-sync-\(UUID().uuidString.prefix(6))"
        
        wsClient.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processMessage(message, subId: subId, endpoints: endpoints, index: index, since: since)
            }
            .store(in: &cancellables)
        
        wsClient.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .connected:
                    self.syncStatus = "Fetching from \(url.host ?? "Mac relay")..."
                    self.sendSyncRequest(to: wsClient, subId: subId, url: url, since: since)
                case .error:
                    #if DEBUG
                    print("MacRelaySyncService: Connection error to \(endpoint)")
                    #endif
                    self.syncStatus = "Connection error"
                    // Try next endpoint
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.syncFromEndpoints(endpoints, index: index + 1, since: since)
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        wsClient.connect(url: url)
        
        // Safety timeout: if nothing happens in 30 seconds, move on
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.isSyncing else { return }
            // If we're still trying to fetch from this endpoint, move on
            if self.client === wsClient && wsClient.connectionState != .disconnected {
                #if DEBUG
                print("MacRelaySyncService: Timeout for \(endpoint), moving to next")
                #endif
                wsClient.disconnect()
                self.syncFromEndpoints(endpoints, index: index + 1, since: since)
            }
        }
    }
    
    private func sendSyncRequest(to client: WebSocketClient, subId: String, url: URL, since: Int64) {
        // Resolve ownerHex directly from config to be safe
        let npub = ConfigService.shared.config.ownerNpub
        let ownerHex = Bech32.decode(npub)?.hexString ?? ""
        
        if ownerHex.isEmpty {
            #if DEBUG
            print("MacRelaySyncService: Owner Hex is empty, cannot filter correctly")
            #endif
        }

        // Kinds: Profile (0), Note (1), Contacts (3), DM (4), Repost (6), Reaction (7), 
        // File Metadata (1063), Long-form (30023), Zap (9735), GiftWrap (1059)
        let kinds = [0, 1, 3, 4, 6, 7, 1059, 1063, 30023, 9735]
        
        // Strategy: Since the Mac relay is a PRIVATE relay for this owner, it only contains 
        // data the user cares about (their notes, notes from people they follow, and mentions).
        // Therefore, we don't strictly NEED the authors list — we can just request ALL events 
        // of relevant kinds since our last sync.
        
        var filter1: [String: Any] = [
            "kinds": kinds,
            "limit": 20000
        ]
        
        if since > 0 {
            filter1["since"] = since
        }
        
        var filters: [Any] = [filter1]
        
        // Filter 2: Explicit mentions of the owner (Double-check inbox/mentions)
        if !ownerHex.isEmpty {
            var filter2: [String: Any] = [
                "kinds": kinds,
                "#p": [ownerHex],
                "limit": 5000
            ]
            if since > 0 {
                filter2["since"] = since
            }
            filters.append(filter2)
        }
        
        // Send filters
        let req: [Any] = ["REQ", subId] + filters

        
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            #if DEBUG
            print("MacRelaySyncService: Syncing from \(url.path) since \(since) with p-tags(\(ownerHex.prefix(8)))")
            #endif
            client.send(text: str)
        }
    }
    
    private func processMessage(_ message: String, subId: String, endpoints: [String], index: Int, since: Int64) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let type = json[0] as? String else { return }
        
        if type == "EOSE" {
            // End of stored events — close this subscription and move on
            let closeMsg: [Any] = ["CLOSE", subId]
            if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
               let closeStr = String(data: closeData, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in
                    self?.client?.send(text: closeStr)
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.client?.disconnect()
                self.syncFromEndpoints(endpoints, index: index + 1, since: since)
            }
            return
        }
        
        guard type == "EVENT", json.count >= 3,
              let eventDict = json[2] as? [String: Any],
              let eventId = eventDict["id"] as? String else { return }
        
        // Deduplicate
        if syncedEventIds.contains(eventId) { return }
        syncedEventIds.insert(eventId)
        
        // Buffer the raw event dict for later injection into local relay
        pendingEvents.append(eventDict)
        
        DispatchQueue.main.async { [weak self] in
            self?.notesSynced = self?.syncedEventIds.count ?? 0
            self?.syncStatus = "Synced \(self?.notesSynced ?? 0) notes..."
        }
    }

    
    // MARK: - Finish & Inject into Local Relay
    
    private func finishSync() {
        guard !pendingEvents.isEmpty else {
            isSyncing = false
            syncStatus = "Already up to date"
            lastSyncDate = Date()
            #if DEBUG
            print("MacRelaySyncService: No new events found on Mac relay.")
            #endif
            return
        }

        syncStatus = "Saving \(pendingEvents.count) events to local relay..."

        #if DEBUG
        print("MacRelaySyncService: Injecting \(pendingEvents.count) events into local relay")
        #endif

        let localURLStr = ConfigService.shared.config.nostrURL
        guard let outboxURL = URL(string: localURLStr),
              let inboxURL = URL(string: localURLStr + "/inbox") else {
            syncStatus = "Error: Invalid local relay URL"
            isSyncing = false
            return
        }

        // Partition events: owner/whitelisted go to outbox, tagged notes go to inbox
        let whitelisted = ConfigService.shared.whitelistedHexPubkeys
        var outboxEvents: [[String: Any]] = []
        var inboxEvents: [[String: Any]] = []

        for eventDict in pendingEvents {
            if let pubkey = eventDict["pubkey"] as? String, whitelisted.contains(pubkey) {
                outboxEvents.append(eventDict)
            } else {
                inboxEvents.append(eventDict)
            }
        }

        #if DEBUG
        print("MacRelaySyncService: Routing \(outboxEvents.count) to outbox, \(inboxEvents.count) to inbox")
        #endif

        let allEvents = pendingEvents
        let group = DispatchGroup()
        var maxTimestamp: Int64 = self.lastSyncTimestamp

        // Helper: send a batch of events to a specific relay endpoint
        func injectEvents(_ events: [[String: Any]], to url: URL, label: String) {
            guard !events.isEmpty else { return }
            group.enter()

            let client = WebSocketClient()
            client.isTemporary = true

            client.$connectionState
                .receive(on: processingQueue)
                .sink { state in
                    if state == .connected {
                        let batchSize = 100
                        for i in stride(from: 0, to: events.count, by: batchSize) {
                            let end = min(i + batchSize, events.count)
                            for eventDict in events[i..<end] {
                                let msg: [Any] = ["EVENT", eventDict]
                                if let data = try? JSONSerialization.data(withJSONObject: msg),
                                   let str = String(data: data, encoding: .utf8) {
                                    client.send(text: str)
                                }
                            }
                            if i + batchSize < events.count {
                                Thread.sleep(forTimeInterval: 0.1)
                            }
                        }

                        let delay = max(2.0, Double(events.count) / 500.0)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            client.disconnect()
                            #if DEBUG
                            print("MacRelaySyncService: \(label) injection done (\(events.count) events)")
                            #endif
                            group.leave()
                        }
                    } else if state == .error {
                        #if DEBUG
                        print("MacRelaySyncService: \(label) connection error")
                        #endif
                        group.leave()
                    }
                }
                .store(in: &self.cancellables)

            client.connect(url: url)
        }

        // Track max timestamp across all events
        for eventDict in allEvents {
            if let ts = eventDict["created_at"] as? Int64 {
                maxTimestamp = max(maxTimestamp, ts)
            } else if let ts = eventDict["created_at"] as? Int {
                maxTimestamp = max(maxTimestamp, Int64(ts))
            }
        }

        injectEvents(outboxEvents, to: outboxURL, label: "outbox")
        injectEvents(inboxEvents, to: inboxURL, label: "inbox")

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let nowTimestamp = Int64(Date().timeIntervalSince1970)
            self.lastSyncTimestamp = min(maxTimestamp, nowTimestamp)
            self.isSyncing = false
            self.lastSyncDate = Date()
            self.syncStatus = "Synced \(allEvents.count) notes"

            #if DEBUG
            print("MacRelaySyncService: Sync complete — \(allEvents.count) events injected, maxTimestamp=\(maxTimestamp)")
            #endif

            NotificationCenter.default.post(name: .macRelaySyncComplete, object: nil)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let macRelaySyncComplete = Notification.Name("macRelaySyncComplete")
}

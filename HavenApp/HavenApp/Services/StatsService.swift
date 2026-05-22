import Foundation
import Combine

@MainActor
class StatsService: ObservableObject {
    static let shared = StatsService()
    
    @Published var storageSize: Int64 = 0
    @Published var blossomSize: Int64 = 0
    @Published var cacheSize: Int64 = 0
    @Published var loadedEventsCount: Int = UserDefaults.standard.integer(forKey: "haven.stats.eventCount")
    @Published var isUpdatingCount: Bool = false
    
    private var nostrService = NostrService.shared
    private var relayManager = RelayProcessManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Tracking for real-time updates
    private var baseDbCount: Int = 0
    private var baseRelayNotesStored: Int = 0
    /// Prevents the observer from overwriting the UserDefaults-loaded count
    /// before `refreshStats` has fetched the real DB count at least once.
    private var hasEstablishedBaseline: Bool = false
    
    init() {
        // Observe RelayProcessManager for new incoming events (real-time updates)
        relayManager.$eventsStored
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (newNoteCount: Int) in
                guard let self = self, self.hasEstablishedBaseline else { return }
                
                // If eventsStored was reset (e.g. after import),
                // realign the baselines so the diff tracking starts fresh.
                if newNoteCount < self.baseRelayNotesStored {
                    self.baseRelayNotesStored = 0
                    self.baseDbCount = self.loadedEventsCount
                }
                
                // diff is how many new events came in since we last fetched the DB count
                let diff = newNoteCount - self.baseRelayNotesStored
                if diff >= 0 {
                    let newCount = self.baseDbCount + diff
                    self.loadedEventsCount = newCount
                    UserDefaults.standard.set(newCount, forKey: "haven.stats.eventCount")
                }
            }
            .store(in: &cancellables)
    }
    
    func refreshStats(relayURLString: String? = nil) {
        if isUpdatingCount { return }
        self.isUpdatingCount = true
        
        Task { @MainActor in
            defer { self.isUpdatingCount = false }
            
            let relayDir = ConfigService.shared.relayDataDir
            let blossomDir = relayDir.appendingPathComponent("blossom")
            let cacheDir = relayDir.appendingPathComponent("cache")
            
            // Perform heavy I/O in a background task
            let (storage, blossom, cache) = await Task.detached(priority: .userInitiated) {
                let s = self.calculateSize(of: relayDir)
                let b = self.calculateSize(of: blossomDir)
                let c = self.calculateSize(of: cacheDir)
                return (s, b, c)
            }.value
            
            self.storageSize = storage
            self.blossomSize = blossom
            self.cacheSize = cache
            
            // Fetch persistent count if URL provided
            if let _ = relayURLString {
                let config = ConfigService.shared.config
                
                // Construct internal URLs for Outbox (root) and Inbox (tagged notes)
                // We ALWAYS use 127.0.0.1 for the internal stats fetch to bypass loopback/domain issues
                // even if config.nostrURL is set to a public domain.
                // macOS relay runs plain HTTP/WS; iOS relay runs HTTPS/WSS (self-signed cert)
                #if os(macOS)
                let baseURLString = "ws://127.0.0.1:\(config.relayPort)"
                #else
                let baseURLString = "wss://127.0.0.1:\(config.relayPort)"
                #endif
                guard let baseURL = URL(string: baseURLString) else {
                    #if DEBUG
                    print("StatsService: ❌ Invalid baseURL for stats: \(baseURLString)")
                    #endif
                    return
                }
                
                let relayURLs = [
                    baseURL,
                    baseURL.appendingPathComponent("inbox")
                ]
                
                #if DEBUG
                print("StatsService: 🔄 Starting full count refresh from: \(relayURLs.map { $0.absoluteString })")
                #endif
                
                // Now on MainActor, we can safely access RelayProcessManager.shared
                if RelayProcessManager.shared.isRunning {
                    #if DEBUG
                    print("StatsService: 📡 Calling fetchCount for all events...")
                    #endif
                    
                    var count = await self.nostrService.fetchCount(from: relayURLs, filter: [:])
                    
                    #if DEBUG
                    print("StatsService: 📩 fetchCount returned: events=\(String(describing: count))")
                    #endif
                    
                    // If we get 0 but previously had a count, retry once after a short delay
                    if (count ?? 0) == 0 && (self.loadedEventsCount > 0 || !RelayProcessManager.shared.isBooting) {
                        #if DEBUG
                        print("StatsService: ⚠️ Fetch returned 0 for events. Retrying once...")
                        #endif
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        count = await self.nostrService.fetchCount(from: relayURLs, filter: [:])
                    }
                    
                    // Guard: Only update events if we have a valid non-zero count, or if our current count is 0
                    if let confirmedCount = count, (confirmedCount > 0 || self.loadedEventsCount == 0) {
                        #if DEBUG
                        print("StatsService: ✨ Total aggregated events count: \(confirmedCount)")
                        #endif
                        self.baseDbCount = confirmedCount
                        self.baseRelayNotesStored = RelayProcessManager.shared.eventsStored
                        self.hasEstablishedBaseline = true
                        
                        self.loadedEventsCount = confirmedCount
                        UserDefaults.standard.set(confirmedCount, forKey: "haven.stats.eventCount")
                    } else {
                        #if DEBUG
                        print("StatsService: ❌ Fetch failed or returned 0 for events. Keeping old count: \(self.loadedEventsCount)")
                        #endif
                    }
                } else {
                    #if DEBUG
                    print("StatsService: ⏭️ Skipping fetch - relay not running (State: \(RelayProcessManager.shared.state))")
                    #endif
                    
                    // If it's NOT running but we are still updating, let's at least clear the spinner if count is 0
                    if self.loadedEventsCount == 0 {
                        // Keep it 0 but stop the loading state
                    }
                }
            } else {
                #if DEBUG
                print("StatsService: ℹ️ refreshStats called without relayURLString, only updated disk sizes.")
                #endif
            }
        }
    }
    
    /// Fetches event counts per kind from the local relay. Uses one WebSocket per relay
    /// endpoint and pipelines all COUNT requests through it to avoid hitting the connection
    /// rate limiter. Returns a dictionary mapping kind number to count, plus the total under key -1.
    func fetchCountsByKind() async -> [Int: Int] {
        let config = ConfigService.shared.config
        #if os(macOS)
        let baseURLString = "ws://127.0.0.1:\(config.relayPort)"
        #else
        let baseURLString = "wss://127.0.0.1:\(config.relayPort)"
        #endif
        guard let baseURL = URL(string: baseURLString) else { return [:] }

        let relayURLs = [
            baseURL,
            baseURL.appendingPathComponent("inbox")
        ]

        // Common Nostr kinds to query — covers profile, social, media, lists, long-form, zaps, DMs
        let kindsToQuery = [
            0, 1, 3, 4, 5, 6, 7, 8, 9, 16,
            1059, 1063, 1311, 1808,
            9734, 9735,
            10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030,
            30000, 30001, 30002, 30008, 30009, 30023, 30024, 30030, 30078
        ]

        var results: [Int: Int] = [:]

        // One connection per URL, pipeline all COUNT requests through it
        await withTaskGroup(of: [Int: Int].self) { group in
            for url in relayURLs {
                group.addTask {
                    return await Self.fetchKindCounts(url: url, kinds: kindsToQuery)
                }
            }
            for await partial in group {
                for (kind, count) in partial {
                    results[kind, default: 0] += count
                }
            }
        }

        return results
    }

    /// Opens a single WebSocket to the relay URL and sends one COUNT per kind plus a total.
    /// Returns kind -> count, with the grand total under key -1.
    private static func fetchKindCounts(url: URL, kinds: [Int]) async -> [Int: Int] {
        let client = await MainActor.run { () -> WebSocketClient in
            let c = WebSocketClient()
            c.isTemporary = true
            return c
        }
        await MainActor.run { client.connect(url: url) }

        // Wait for connection (5s timeout)
        var connectCancellable: AnyCancellable?
        let didConnect = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            connectCancellable = client.$connectionState
                .first(where: { $0 == .connected || $0 == .error })
                .timeout(.seconds(5), scheduler: DispatchQueue.main)
                .sink { completion in
                    if !resumed { resumed = true
                        if case .failure = completion { cont.resume(returning: false) }
                        else { cont.resume(returning: false) }
                    }
                } receiveValue: { state in
                    if !resumed { resumed = true; cont.resume(returning: state == .connected) }
                }
        }
        _ = connectCancellable
        guard didConnect else {
            await MainActor.run { client.disconnect() }
            return [:]
        }

        // Assign a unique sub ID per kind (and -1 for total)
        var subIdToKind: [String: Int] = [:]
        var pending: Set<String> = []
        let totalSubId = "count-total-\(UUID().uuidString.prefix(6))"
        subIdToKind[totalSubId] = -1
        pending.insert(totalSubId)
        for kind in kinds {
            let subId = "count-k\(kind)-\(UUID().uuidString.prefix(6))"
            subIdToKind[subId] = kind
            pending.insert(subId)
        }

        var results: [Int: Int] = [:]

        var messageCancellable: AnyCancellable?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            messageCancellable = client.messageSubject
                .receive(on: DispatchQueue.main)
                .timeout(.seconds(20), scheduler: DispatchQueue.main)
                .sink { _ in
                    if !resumed { resumed = true; cont.resume() }
                } receiveValue: { msg in
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          json.count >= 3,
                          let type = json[0] as? String,
                          let subId = json[1] as? String,
                          type == "COUNT",
                          let kind = subIdToKind[subId],
                          let payload = json[2] as? [String: Any],
                          let rawCount = payload["count"] else { return }

                    let extracted: Int
                    if let i = rawCount as? Int { extracted = i }
                    else if let d = rawCount as? Double { extracted = Int(d) }
                    else if let n = rawCount as? NSNumber { extracted = n.intValue }
                    else if let s = rawCount as? String, let i = Int(s) { extracted = i }
                    else { extracted = 0 }

                    results[kind] = extracted
                    pending.remove(subId)
                    if pending.isEmpty, !resumed { resumed = true; cont.resume() }
                }

            // Fire all COUNT requests
            DispatchQueue.main.async {
                let totalReq: [Any] = ["COUNT", totalSubId, [:] as [String: Any]]
                if let d = try? JSONSerialization.data(withJSONObject: totalReq),
                   let s = String(data: d, encoding: .utf8) {
                    client.send(text: s)
                }
                for kind in kinds {
                    let subId = subIdToKind.first(where: { $0.value == kind })?.key ?? ""
                    let req: [Any] = ["COUNT", subId, ["kinds": [kind]] as [String: Any]]
                    if let d = try? JSONSerialization.data(withJSONObject: req),
                       let s = String(data: d, encoding: .utf8) {
                        client.send(text: s)
                    }
                }
            }
        }
        _ = messageCancellable

        await MainActor.run { client.disconnect() }
        return results
    }

    nonisolated private func calculateSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // Skip the blossom directory for the main storage count to avoid double counting if desired?
            // "Storage Used" usually implies *total* used by the app.
            // "Media Storage" is a subset.
            // I'll count total for storage, and specific for media.
            if let attributes = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let size = attributes.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }
    
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file)
    }
    
    var formattedBlossomSize: String {
        ByteCountFormatter.string(fromByteCount: blossomSize, countStyle: .file)
    }
    
    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }
}

import Foundation
import Combine

@MainActor
class StatsService: ObservableObject {
    static let shared = StatsService()
    
    @Published var storageSize: Int64 = 0
    @Published var blossomSize: Int64 = 0
    @Published var cacheSize: Int64 = 0
    @Published var loadedNotesCount: Int = UserDefaults.standard.integer(forKey: "haven.stats.noteCount")
    @Published var isUpdatingCount: Bool = false
    
    private var nostrService = NostrService.shared
    private var relayManager = RelayProcessManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Tracking for real-time updates
    private var baseDbCount: Int = 0
    private var baseRelayEventsStored: Int = 0
    
    init() {
        // Observe RelayProcessManager for new incoming events (real-time updates)
        relayManager.$eventsStored
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newEventCount in
                guard let self = self else { return }
                // diff is how many new events came in since we last fetched the DB count
                let diff = newEventCount - self.baseRelayEventsStored
                if diff >= 0 {
                    let newCount = self.baseDbCount + diff
                    self.loadedNotesCount = newCount
                    UserDefaults.standard.set(newCount, forKey: "haven.stats.noteCount")
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
                let baseURLString = "ws://127.0.0.1:\(config.relayPort)"
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
                    let filter: [String: Any] = ["kinds": [1, 6, 1063]]
                    
                    #if DEBUG
                    print("StatsService: 📡 Calling fetchCount...")
                    #endif
                    var count = await self.nostrService.fetchCount(from: relayURLs, filter: filter)
                    #if DEBUG
                    print("StatsService: 📩 fetchCount returned: \(String(describing: count))")
                    #endif
                    
                    // If we get 0, but previously had a much higher count, be skeptical.
                    if (count ?? 0) == 0 && self.loadedNotesCount > 0 {
                        #if DEBUG
                        print("StatsService: ⚠️ Fetch returned 0 while previous count was \(self.loadedNotesCount). Retrying with delay...")
                        #endif
                        for i in 1...3 {
                            try? await Task.sleep(nanoseconds: UInt64(i) * 2 * 1_000_000_000)
                            #if DEBUG
                            print("StatsService: 🔄 Retry \(i)...")
                            #endif
                            count = await self.nostrService.fetchCount(from: relayURLs, filter: filter)
                            if (count ?? 0) > 0 { 
                                #if DEBUG
                                print("StatsService: ✅ Retry \(i) succeeded with \(count!)")
                                #endif
                                break 
                            }
                        }
                    } else if (count ?? 0) == 0 && !RelayProcessManager.shared.isBooting {
                        #if DEBUG
                        print("StatsService: ⚠️ Fetch returned 0. Retrying once to confirm...")
                        #endif
                        try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                        count = await self.nostrService.fetchCount(from: relayURLs, filter: filter)
                    }
                    
                    // Guard: Only update if we have a valid non-zero count, or if our current count is 0
                    if let confirmedCount = count, (confirmedCount > 0 || self.loadedNotesCount == 0) {
                        #if DEBUG
                        print("StatsService: ✨ Total aggregated count: \(confirmedCount)")
                        #endif
                        self.baseDbCount = confirmedCount
                        self.baseRelayEventsStored = RelayProcessManager.shared.eventsStored
                        
                        self.loadedNotesCount = confirmedCount
                        UserDefaults.standard.set(confirmedCount, forKey: "haven.stats.noteCount")
                    } else {
                        #if DEBUG
                        print("StatsService: ❌ Fetch failed or returned 0. Keeping old count: \(self.loadedNotesCount)")
                        #endif
                    }
                } else {
                    #if DEBUG
                    print("StatsService: ⏭️ Skipping fetch - relay not running (State: \(RelayProcessManager.shared.state))")
                    #endif
                    
                    // If it's NOT running but we are still updating, let's at least clear the spinner if count is 0
                    if self.loadedNotesCount == 0 {
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

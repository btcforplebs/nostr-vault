import Foundation
import Combine

@MainActor
class StatsService: ObservableObject {
    @Published var storageSize: Int64 = 0
    @Published var blossomSize: Int64 = 0
    @Published var cacheSize: Int64 = 0
    @Published var loadedNotesCount: Int = UserDefaults.standard.integer(forKey: "haven.stats.noteCount")
    @Published var isUpdatingCount: Bool = UserDefaults.standard.integer(forKey: "haven.stats.noteCount") == 0
    
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
            
        refreshStats()
    }
    
    func refreshStats(relayURLString: String? = nil) {
        Task { @MainActor in
            self.isUpdatingCount = true
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
            if let _ = relayURLString,
               let baseURL = URL(string: ConfigService.shared.config.nostrURL) {
                
                // Construct URLs for Outbox (root) and Inbox (tagged notes)
                let outboxURL = baseURL
                let inboxURL = baseURL.appendingPathComponent("inbox")
                let relayURLs = [outboxURL, inboxURL]
                
                print("StatsService: Fetching counts from \(relayURLs.map { $0.absoluteString })")
                
                // Now on MainActor, we can safely access RelayProcessManager.shared
                if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isImporting && !RelayProcessManager.shared.isBooting {
                    
                    let filter: [String: Any] = ["kinds": [1, 6, 1063]]
                    
                    var count = await self.nostrService.fetchCount(from: relayURLs, filter: filter)
                    
                    // If we get 0, but previously had a much higher count, be skeptical.
                    if count == 0 && self.loadedNotesCount > 0 {
                        print("StatsService: Fetch returned 0 while previous count was \(self.loadedNotesCount). Retrying with delay...")
                        for i in 1...3 {
                            try? await Task.sleep(nanoseconds: UInt64(i) * 2 * 1_000_000_000)
                            count = await self.nostrService.fetchCount(from: relayURLs, filter: filter)
                            if (count ?? 0) > 0 { break }
                        }
                    } else if count == 0 {
                        print("StatsService: Fetch returned 0. Retrying once to confirm...")
                        try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                        count = await self.nostrService.fetchCount(from: relayURLs, filter: filter)
                    }
                    
                    if let confirmedCount = count {
                        print("StatsService: Total aggregated count: \(confirmedCount)")
                        self.baseDbCount = confirmedCount
                        self.baseRelayEventsStored = RelayProcessManager.shared.eventsStored
                        
                        self.loadedNotesCount = confirmedCount
                        UserDefaults.standard.set(confirmedCount, forKey: "haven.stats.noteCount")
                    } else {
                        print("StatsService: Fetch failed (nil). Keeping old count.")
                    }
                }
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

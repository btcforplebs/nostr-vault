import Foundation
import Combine
import SwiftUI
import CryptoKit

class WebSocketClient: NSObject, ObservableObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum ConnectionState: String {
        case disconnected
        case connecting
        case connected
        case error
    }

    private var webSocketTask: URLSessionWebSocketTask?
    @Published var connectionState: ConnectionState = .disconnected
    private var lastError: String?
    private var isClosing = false
    var isTemporary = false
    let messageSubject = PassthroughSubject<String, Never>()
    
    private var url: URL?
    
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config)
    }()
    
    func connect(url: URL) {
        self.url = url
        disconnect()
        
        if !isTemporary {
            print("WebSocketClient: Connecting to \(url.absoluteString)")
        }
        isClosing = false
        DispatchQueue.main.async {
            self.connectionState = .connecting
            self.lastError = nil
        }
        
        var request = URLRequest(url: url)
        request.setValue("Haven/1.0", forHTTPHeaderField: "User-Agent")
        
        let task = Self.session.webSocketTask(with: request)
        task.delegate = self
        webSocketTask = task
        task.resume()
        receiveMessage()
    }
    
    func disconnect() {
        isClosing = true
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
    }
    
    func send(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }
    
    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            switch result {
            case .failure(let error):
                if self?.isClosing == false {
                    print("WebSocket receive failure: \(error.localizedDescription)")
                    Task { @MainActor in
                        self?.connectionState = .error
                        self?.lastError = error.localizedDescription
                    }
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    print("WebSocketClient [\(self?.url?.lastPathComponent ?? "root")]: Received: \(text.prefix(100))")
                    self?.messageSubject.send(text)
                case .data(_):
                    break
                @unknown default:
                    break
                }
                self?.receiveMessage()
            }
        }
    }
    
    // MARK: - URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if !isTemporary {
            print("WebSocketClient: Connected to \(url?.absoluteString ?? "unknown")")
        }
        DispatchQueue.main.async { self.connectionState = .connected }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if !isClosing {
            print("WebSocketClient: Closed with code \(closeCode)")
        }
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("WebSocketClient: Completed with error: \(error.localizedDescription)")
            DispatchQueue.main.async { 
                self.connectionState = .error
                self.lastError = error.localizedDescription
            }
        }
    }
}

@MainActor
class NostrService: ObservableObject {
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
    }
    
    static let shared = NostrService()
    // These are no longer @Published to prevent background-thread notification crashes.
    // We notify manually on the main thread via the throttled subject.
    private(set) var events: [NostrEvent] = []
    private(set) var noteMedia: [MediaItem] = []
    
    // Aggregated status
    @Published var connectionStatus: String = "Disconnected"
    @Published var connectionColor: String = "gray"
    @Published var isFetching: Bool = false
    
    private var seenEventIds = Set<String>()
    private var clients: [String: WebSocketClient] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let processingQueue = DispatchQueue(label: "com.haven.nostr-processing", qos: .userInitiated)
    
    // Batching updates to the UI
    private let eventUpdateSubject = PassthroughSubject<Void, Never>()
    
    // Pagination tracking
    private var activeSubscriptionCount = 0
    private var profilesInFlight = Set<String>()
    private var profileFetchQueue = Set<String>()
    private var profileFlushCancellable: AnyCancellable?
    
    init() {
        setupThrottling()
        loadProfiles()
        updateOwnerHex()
    }
    
    private(set) var profileNames: [String: String] = [:]
    private(set) var profilePictures: [String: URL] = [:]
    private(set) var ownerHexPubkey: String = ""
    
    private func updateOwnerHex() {
        let npub = ConfigService.shared.config.ownerNpub
        if let hex = Bech32.decode(npub)?.hexString {
            self.ownerHexPubkey = hex
            print("NostrService: Owner Hex Pubkey: \(hex)")
        }
    }
    
    private func setupMetadataFlusher() {
        profileFlushCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.flushMetadataRequests()
            }
    }
    
    private func flushMetadataRequests() {
        guard !profileFetchQueue.isEmpty else { return }
        let pubkeys = Array(profileFetchQueue)
        profileFetchQueue.removeAll()
        
        // Use blastr relays or defaults if empty
        var relays = ConfigService.shared.config.blastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }
        
        print("NostrService: Batch fetching metadata for \(pubkeys.count) pubkeys from \(relays.count) Blastr relays")
        
        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }
        
        for url in uniqueRelays {
            let client = WebSocketClient()
            client.isTemporary = true
            
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message)
                }
                .store(in: &cancellables)
            
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    if state == .connected {
                        self?.sendProfileRequest(to: client, pubkeys: pubkeys)
                        // Disconnect after results come in (or reasonable timeout)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)
            
            client.connect(url: url)
        }
    }
    
    private func loadProfiles() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let profileURL = havenDir.appendingPathComponent("profiles.json")
        
        if let data = try? Data(contentsOf: profileURL),
           let loaded = try? JSONDecoder().decode(ProfileCache.self, from: data) {
            self.profileNames = loaded.names
            self.profilePictures = loaded.pictures
            print("NostrService: Loaded \(profileNames.count) names and \(profilePictures.count) pictures from cache")
        }
    }
    
    private struct ProfileCache: Codable {
        let names: [String: String]
        let pictures: [String: URL]
    }
    
    private func saveProfiles() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let profileURL = havenDir.appendingPathComponent("profiles.json")
        
        let cache = ProfileCache(names: profileNames, pictures: profilePictures)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: profileURL)
        }
    }
    
    func fetchMissingProfiles(for pubkeys: [String]) {
        let missing = pubkeys.filter { profileNames[$0] == nil && !profilesInFlight.contains($0) }
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
            "kinds": [0],
            "authors": pubkeys
        ]
        
        let req = ["REQ", subscriptionId, filter] as [Any]
        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            client.send(text: reqString)
        }
    }
    
    func resetConnections() {
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
        cancellables.removeAll()
        setupThrottling()
    }
    
    private func setupThrottling() {
        // Debounce UI updates to prevent main thread saturation and fix NSStatusItem threading crash
        eventUpdateSubject
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    
    func fetchNotes(from relayURLs: [URL], until: Int64? = nil) {
        DispatchQueue.main.async { 
            self.isFetching = true 
            self.activeSubscriptionCount = relayURLs.count
        }
        for url in relayURLs {
            let urlString = url.absoluteString
            
            // For pagination, we always want to create a new request even if client exists
            if let existing = clients[urlString] {
                if existing.connectionState == .connected {
                    sendRequest(to: existing, url: url, until: until)
                    continue
                } else if existing.connectionState == .connecting {
                    continue
                }
            }
            
            let client = WebSocketClient()
            clients[urlString] = client
            
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message)
                }
                .store(in: &cancellables)
            
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.updateAggregatedStatus()
                    if state == .connected {
                        self?.sendRequest(to: client, url: url, until: until)
                    }
                }
                .store(in: &cancellables)
            
            client.connect(url: url)
        }
    }
    
    private func sendRequest(to client: WebSocketClient, url: URL, until: Int64? = nil) {
        let subscriptionId = "viewer-\(url.lastPathComponent.isEmpty ? "root" : url.lastPathComponent)-\(UUID().uuidString.prefix(4))"
        // Request events with a limit to get the latest data. 
        // Also include common kinds (1: text, 6: repost, 1063: file metadata) to avoid empty filter blocks
        // Added 0 for profiles
        var filter: [String: Any] = [
            "limit": 500,
            "kinds": [0, 1, 6, 1063]
        ]
        if let until = until {
            filter["until"] = until
        }
        
        let req = ["REQ", subscriptionId, filter] as [Any]
        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            print("NostrService: Sending REQ to \(url.absoluteString): \(reqString)")
            client.send(text: reqString)
        }
    }
    
    private func updateAggregatedStatus() {
        let states = clients.values.map { $0.connectionState }
        if states.contains(.connected) {
            connectionStatus = "Connected"
            connectionColor = "green"
        } else if states.contains(.connecting) {
            connectionStatus = "Connecting..."
            connectionColor = "yellow"
        } else if states.contains(.error) {
            connectionStatus = "Connection Error"
            connectionColor = "red"
        } else {
            connectionStatus = "Disconnected"
            connectionColor = "gray"
        }
    }
    
    private func processMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let type = json[0] as? String else { 
            print("NostrService: Failed to parse message: \(message.prefix(100))...")
            return 
        }

        if type != "EVENT" {
            print("NostrService: Received \(type) from relay: \(message)")
            
            if type == "EOSE" {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.activeSubscriptionCount -= 1
                    if self.activeSubscriptionCount <= 0 {
                        self.isFetching = false
                        self.activeSubscriptionCount = 0
                    }
                    self.events.sort(by: { $0.created_at > $1.created_at })
                    self.eventUpdateSubject.send()
                }
            }
        }

        if type != "EVENT" { return }
        
        guard json.count >= 3 else { return }
        
        if let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
            
            if event.kind == 0 {
                // Handling Kind 0 (Metadata)
                if let metadata = try? JSONSerialization.jsonObject(with: event.content.data(using: .utf8) ?? Data()) as? [String: Any] {
                    let name = (metadata["display_name"] as? String) ?? (metadata["name"] as? String) ?? (metadata["username"] as? String)
                    let picture = (metadata["picture"] as? String).flatMap { URL(string: $0) }
                    
                    DispatchQueue.main.async { [weak self] in
                        var changed = false
                        if let name = name, !name.isEmpty {
                            self?.profileNames[event.pubkey] = name
                            changed = true
                        }
                        if let picture = picture {
                            self?.profilePictures[event.pubkey] = picture
                            changed = true
                        }
                        
                        if changed {
                            self?.profilesInFlight.remove(event.pubkey)
                            self?.saveProfiles()
                            self?.eventUpdateSubject.send()
                        }
                    }
                }
                return // Metadata doesn't need to be in the events list
            }

            if seenEventIds.contains(event.id) { return }
            seenEventIds.insert(event.id)
            
            var items: [MediaItem] = []
            
            if event.kind == 1063 {
                // Parse KIND 1063 url tag
                if let urlTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "url" }),
                   let url = URL(string: urlTag[1]) {
                    let mediaType: MediaItem.MediaType = url.isVideo ? .video : .image
                    items.append(MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags))
                }
            } else {
                let urls = extractMediaURLs(from: event.content)
                items = urls.map { url in
                    let mediaType: MediaItem.MediaType = url.isVideo ? .video : .image
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags)
                }
            }
            
            // Perform sorting and limiting on main thread to ensure safety
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Store all events so they show up in the viewer
                self.events.append(event)
                
                if !items.isEmpty {
                    self.noteMedia.append(contentsOf: items)
                }
                
                // Only sort occasionally or if we have a burst finished
                if self.events.count % 20 == 0 || items.count > 0 {
                    self.events.sort(by: { $0.created_at > $1.created_at })
                    if self.events.count > 10000 {
                        self.events = Array(self.events.prefix(10000))
                    }
                }
                
                // Signal UI update - this will be throttled and sent on main thread
                self.eventUpdateSubject.send()
            }
        }
    }
    
    func fetchCount(from relayURLs: [URL], filter: [String: Any] = [:]) async -> Int? {
        print("NostrService: Starting aggregate fetchCount for \(relayURLs.count) relays")
        var totalCount: Int? = nil
        
        let safeFilter = UncheckedSendable(value: filter)
        
        await withTaskGroup(of: Int?.self) { group in
            for url in relayURLs {
                group.addTask {
                    let filter = safeFilter.value
                    let urlString = url.absoluteString
                    let relayTag = url.lastPathComponent.isEmpty ? "outbox" : url.lastPathComponent
                    
                    print("NostrService [\(relayTag)]: Task started")
                    
                    let (client, isNew) = await MainActor.run { () -> (WebSocketClient?, Bool) in
                        if let existing = self.clients[urlString] {
                            print("NostrService [\(relayTag)]: Using existing client")
                            return (existing, false)
                        } else {
                            print("NostrService [\(relayTag)]: Creating new client")
                            let newClient = WebSocketClient()
                            newClient.isTemporary = true
                            return (newClient, true)
                        }
                    }
                    
                    guard let client = client else { 
                        print("NostrService [\(relayTag)]: Failed to get client")
                        return nil 
                    }
                    
                    // 1. Wait for connection if needed
                    if client.connectionState != .connected {
                        print("NostrService [\(relayTag)]: Not connected. Connecting now...")
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
                                            print("NostrService [\(relayTag)]: Connection timeout")
                                        }
                                        continuation.resume(returning: false)
                                    }
                                } receiveValue: { state in
                                    if !hasResumed {
                                        hasResumed = true
                                        print("NostrService [\(relayTag)]: Connection state reached: \(state)")
                                        continuation.resume(returning: state == .connected)
                                    }
                                }
                        }
                        _ = cancellable // Hold it until await finishes
                        
                        if !didConnect {
                            print("NostrService [\(relayTag)]: Failed to connect during fetchCount")
                            if isNew { await MainActor.run { client.disconnect() } }
                            return nil
                        }
                    }
                    
                    // 2. Send COUNT and wait for response
                    let subscriptionId = "count-\(UUID().uuidString.prefix(6))"
                    print("NostrService [\(relayTag)]: Sending COUNT with subId: \(subscriptionId)")
                    
                    var messageCancellable: AnyCancellable?
                    let countResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                        var hasResumed = false
                        
                        messageCancellable = client.messageSubject
                            .filter { $0.contains(subscriptionId) }
                            .first()
                            .timeout(.seconds(10), scheduler: DispatchQueue.main)
                            .sink { completion in
                                if !hasResumed {
                                    hasResumed = true
                                    if case .failure = completion {
                                        print("NostrService [\(relayTag)]: COUNT response timeout")
                                    } else {
                                        print("NostrService [\(relayTag)]: Message stream finished before COUNT")
                                    }
                                    continuation.resume(returning: nil)
                                }
                            } receiveValue: { msg in
                                if !hasResumed {
                                    hasResumed = true
                                    print("NostrService [\(relayTag)]: Received response: \(msg.prefix(200))")
                                    
                                    if let data = msg.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                       json.count >= 3,
                                       let result = json[2] as? [String: Any],
                                       let count = (result["count"] as? Int) ?? (result["count"] as? NSNumber)?.intValue {
                                        continuation.resume(returning: count)
                                    } else {
                                        print("NostrService [\(relayTag)]: Failed to parse COUNT JSON")
                                        continuation.resume(returning: nil)
                                    }
                                }
                            }
                        
                        // Send the actual request
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
                        print("NostrService [\(relayTag)]: Disconnecting temporary client")
                        await MainActor.run { client.disconnect() }
                    }
                    
                    print("NostrService [\(relayTag)]: Returning count: \(String(describing: countResult))")
                    return countResult
                }
            }
            
            for await count in group {
                if let count = count {
                     totalCount = (totalCount ?? 0) + count
                }
            }
        }
        
        print("NostrService: Final aggregated count: \(String(describing: totalCount))")
        return totalCount
    }

    func extractMediaURLs(from content: String) -> [URL] {
        let pattern = #"(https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic|tiff)(?:\?\S+)?)|(https?://\S+?/blossom/[a-f0-9]{64})|(https?://\S+?/[a-f0-9]{64})"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
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

class MediaCacheService: ObservableObject, @unchecked Sendable {
    static let shared = MediaCacheService()
    
    private let cacheDirectory: URL
    private var inFlightDownloads: [String: [CheckedContinuation<Data?, Never>]] = [:]
    private let downloadLock = NSLock()
    
    let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheDownloadQueue"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    
    private let blossomDirectory: URL
    
    // Thread-safe copy of local host for non-isolated access
    private var localHost: String = ""
    private let hostLock = NSLock()
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenAppSupport = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let dbDir = havenAppSupport.appendingPathComponent("haven_database", isDirectory: true)
        self.cacheDirectory = dbDir.appendingPathComponent("cache")
        self.blossomDirectory = dbDir.appendingPathComponent("blossom")
        
        createCacheDirectory()
    }
    
    private func createCacheDirectory() {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    func cachePath(for url: URL) -> URL {
        let filename = hash(url: url)
        return cacheDirectory.appendingPathComponent(filename)
    }
    
    func isCached(url: URL) -> Bool {
        let path = cachePath(for: url)
        return FileManager.default.fileExists(atPath: path.path)
    }
    
    func saveToCache(url: URL, data: Data) {
        // Guard: Don't cache extremely small files which are likely error messages/404 pages
        guard data.count > 100 else {
            print("MediaCacheService: Skipping cache for \(url.absoluteString) - data too small (\(data.count) bytes)")
            return
        }
        
        let path = cachePath(for: url)
        do {
            try data.write(to: path)
            print("MediaCacheService: Cached \(url.lastPathComponent) to \(path.path)")
        } catch {
            print("MediaCacheService: Failed to cache \(url.absoluteString): \(error.localizedDescription)")
        }
    }
    
    func loadFromCache(url: URL) -> Data? {
        if let localURL = internalLocalFileURL(for: url) {
            return try? Data(contentsOf: localURL)
        }
        return nil
    }
    
    /// Returns a local file:// URL if the media is cached or exists in Blossom.
    /// This is essential for AVFoundation which often fails to play from localhost/127.0.0.1
    /// or requires specific configurations for local network access.
    func localFileURL(for url: URL) -> URL? {
        // Guard: For local relay URLs (including domains), we MUST use HTTP(S) to preserve 
        // the MIME type hints provided by the Blossom server. Resolving to file:// 
        // causes AVFoundation to fail on extensionless hashed files.
        if isLocalURL(url) {
            return nil
        }
        return internalLocalFileURL(for: url)
    }

    /// Internal version that resolves file paths even for local relay URLs.
    /// Used for components like AVAsset thumbnail generation which can handle raw files.
    func internalLocalFileURL(for url: URL) -> URL? {
        // 1. Try to find if it's a local Blossom file we already have
        let hashValue = self.hash(url: url)
        if hashValue.count == 64 {
            let blossomURL = blossomDirectory.appendingPathComponent(hashValue)
            if FileManager.default.fileExists(atPath: blossomURL.path) {
                return blossomURL
            }
        }
        
        // 2. Try the general cache
        let path = cachePath(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
        }
        
        return nil
    }
    
    func fetchData(url: URL) async -> Data? {
        // Bypass cache for local relay Blossom URLs to avoid redundant storage and preserve MIME handling
        if isLocalURL(url) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    return data
                }
            } catch {
                print("MediaCacheService: Failed to fetch local URL \(url.absoluteString): \(error.localizedDescription)")
            }
            return nil
        }

        let filename = hash(url: url)
        if let cachedData = try? Data(contentsOf: cacheDirectory.appendingPathComponent(filename)) {
            return cachedData
        }
        
        return await withCheckedContinuation { continuation in
            downloadLock.lock()
            if var waiters = inFlightDownloads[filename] {
                waiters.append(continuation)
                inFlightDownloads[filename] = waiters
                downloadLock.unlock()
            } else {
                inFlightDownloads[filename] = [continuation]
                downloadLock.unlock()
                
                print("MediaCacheService: Starting download for \(filename) (URL: \(url.absoluteString))")
                // Start the actual download
                URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                    self?.downloadLock.lock()
                    let waiters = self?.inFlightDownloads[filename] ?? []
                    self?.inFlightDownloads.removeValue(forKey: filename)
                    self?.downloadLock.unlock()
                    
                    if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        self?.saveToCache(url: url, data: data)
                        for waiter in waiters {
                            waiter.resume(returning: data)
                        }
                    } else {
                        for waiter in waiters {
                            waiter.resume(returning: nil)
                        }
                    }
                }.resume()
            }
        }
    }
    
    func updateLocalHost(_ host: String) {
        hostLock.lock()
        defer { hostLock.unlock() }
        self.localHost = host.lowercased()
        print("MediaCacheService: Updated local host to \(self.localHost)")
    }
    
    private func isLocalURL(_ url: URL) -> Bool {
        hostLock.lock()
        let sanitized = self.localHost
        hostLock.unlock()
        
        let host = url.host?.lowercased() ?? ""
        
        // Match against localhost, 127.0.0.1
        if host == "localhost" || host == "127.0.0.1" {
            return true
        }
        
        if sanitized.isEmpty { return false }
        
        // Split by colon to ignore port for comparison
        let sanitizedHost = sanitized.split(separator: ":").first.map(String.init) ?? sanitized
        
        return host == sanitizedHost || host.hasSuffix("." + sanitizedHost)
    }
    
    func getSource(for url: URL) -> MediaSource {
        if isLocalURL(url) {
            return .blossom
        } else if isCached(url: url) {
            return .cached
        } else {
            return .remote
        }
    }
    
    private func hash(url: URL) -> String {
        // Optimization: If the URL contains a 64-char Blossom hash, use it directly as the cache key.
        // This aligns with how the Go relay stores files and allows different URLs for the same
        // content (e.g. extensioned vs non-extensioned) to share the cache.
        let last = url.lastPathComponent
        // Check if last component is a 64-char hash, possibly with an extension
        let pattern = #"(^|/)([a-f0-9]{64})(\.[a-z0-9]+)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = last as NSString
            if let match = regex.firstMatch(in: last, options: [], range: NSRange(location: 0, length: ns.length)) {
                // Return just the hash part
                return ns.substring(with: match.range(at: 2)).lowercased()
            }
        }
        
        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Clears the media cache directory while preserving Blossom data
    func clearCache() {
        do {
            let cacheContents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            var deletedCount = 0
            for fileURL in cacheContents {
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }
            print("MediaCacheService: Cleared \(deletedCount) cached files (Blossom data preserved)")
        } catch {
            print("MediaCacheService: Failed to clear cache: \(error.localizedDescription)")
        }
    }
    
    
    enum MediaSource: String {
        case blossom = "Local"
        case cached = "Cached"
        case remote = "Remote"
        
        var isLocal: Bool {
            return self == .blossom
        }
        
        var color: Color {
            switch self {
            case .blossom: return .green
            case .cached: return .blue
            case .remote: return .orange
            }
        }
        
        var icon: String {
            switch self {
            case .blossom: return "server.rack"
            case .cached: return "archivebox.fill"
            case .remote: return "globe"
            }
        }
    }
    
}

struct Bech32 {
    static let alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    
    struct Result {
        let hrp: String
        let data: Data
        
        var hexString: String {
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }
    
    static func decode(_ bechString: String) -> Result? {
        guard !bechString.isEmpty, bechString.count <= 1000 else { return nil } // Nevents can be long
        
        let lower = bechString.lowercased()
        guard let pos = lower.lastIndex(of: "1"), pos != lower.startIndex, pos != lower.index(before: lower.endIndex) else { return nil }
        
        let hrp = String(lower[..<pos])
        let dataString = String(lower[lower.index(after: pos)...])
        
        var data = [UInt8]()
        for char in dataString {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            data.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: index)))
        }
        
        guard data.count >= 6 else { return nil }
        // For simplicity, we'll skip full checksum validation in this helper if it's for internal use,
        // but real Nostr libs use it.
        let coreData = Array(data.prefix(data.count - 6))
        
        // Convert from base32 (5-bit) to base256 (8-bit)
        guard let result = convertBits(data: coreData, from: 5, to: 8, pad: false) else { return nil }
        return Result(hrp: hrp, data: Data(result))
    }
    
    static func encode(hrp: String, data: Data) -> String? {
        guard let converted = convertBits(data: Array(data), from: 8, to: 5, pad: true) else { return nil }
        
        // Simple Bech32 checksum (NIP-19 uses standard Bech32 for most, or Bech32m depending on spec, 
        // but standard Bech32 is common for notes/npubs)
        let checksum = createChecksum(hrp: hrp, data: converted)
        let combined = converted + checksum
        
        var result = hrp + "1"
        for value in combined {
            let index = alphabet.index(alphabet.startIndex, offsetBy: Int(value))
            result.append(alphabet[index])
        }
        return result
    }
    
    // MARK: - TLV Helper
    static func encodeTLV(type: UInt8, data: Data) -> Data {
        var result = Data([type])
        result.append(UInt8(data.count))
        result.append(data)
        return result
    }
    
    // MARK: - Private Helpers
    
    private static func convertBits(data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        let maxv = (1 << to) - 1
        
        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }
        
        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (to - bits)) & maxv))
            }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        
        return result
    }
    
    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = expandHrp(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        var result = [UInt8]()
        for i in 0..<6 {
            result.append(UInt8((mod >> (5 * (5 - i))) & 31))
        }
        return result
    }
    
    private static func expandHrp(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for char in hrp.utf8 {
            result.append(UInt8(char >> 5))
        }
        result.append(0)
        for char in hrp.utf8 {
            result.append(UInt8(char & 31))
        }
        return result
    }
    
    private static func polymod(_ values: [UInt8]) -> Int {
        let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ Int(value)
            for i in 0..<5 {
                if (top >> i) & 1 == 1 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }
    
    static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var tempHex = hex
        if tempHex.count % 2 != 0 { return nil }
        
        while !tempHex.isEmpty {
            let sub = tempHex.prefix(2)
            tempHex = String(tempHex.dropFirst(2))
            if let byte = UInt8(sub, radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
        }
        return data
    }
}

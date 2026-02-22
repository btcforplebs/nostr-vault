import Foundation
import Combine
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Darwin

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
    
    // Keepalive: send a WebSocket ping every 25 s so iOS doesn't kill idle connections
    // ("Operation timed out" / "Socket is not connected" in the OS log).
    private var pingTimer: DispatchSourceTimer?
    private static let pingInterval: TimeInterval = 25
    
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Give the TCP handshake up to 10 s on a local loopback connection.
        config.timeoutIntervalForRequest = 10
        // Keep the overall resource alive indefinitely — our pings do that job.
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()
    
    // Throttle logging to avoid spam during high-frequency events
    private var lastConnectLog: Date = .distantPast
    private var lastReceiveLog: Date = .distantPast
    private var lastClosedLog: Date = .distantPast
    
    private func shouldLogConnect() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastConnectLog) > 5.0 {
            lastConnectLog = now
            return true
        }
        return false
    }
    
    private func shouldLogReceive() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastReceiveLog) > 2.0 {
            lastReceiveLog = now
            return true
        }
        return false
    }
    
    private func shouldLogClosed() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastClosedLog) > 5.0 {
            lastClosedLog = now
            return true
        }
        return false
    }
    
    func connect(url: URL) {
        self.url = url
        disconnect()
        
        if !isTemporary {
            #if DEBUG
            if shouldLogConnect() {
                print("WebSocketClient: Connecting to \(url.absoluteString)")
            }
            #endif
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
        stopPingTimer()
        isClosing = true
        // Guard against "Socket is not connected" OS log noise — only cancel if task exists.
        if let task = webSocketTask {
            task.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
        }
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
    }
    
    func send(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                // Only log send errors occasionally to avoid spam during connectivity issues
                #if DEBUG
                if self?.shouldLogReceive() == true {
                    print("WebSocket send error: \(error)")
                }
                #endif
            }
        }
    }
    
    // MARK: - Keepalive Ping
    
    private func startPingTimer() {
        stopPingTimer()
        guard !isTemporary else { return } // Temporary clients don't need keepalive
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()
        pingTimer = timer
    }
    
    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }
    
    private func sendPing() {
        guard !isClosing, let task = webSocketTask else { return }
        task.sendPing { [weak self] error in
            if let error = error {
                // Ping failed — connection is gone. Transition to error so NostrService retries.
                guard self?.isClosing == false else { return }
                #if DEBUG
                // Reduce ping error spam - only log occasionally
                if self?.shouldLogClosed() == true {
                    print("WebSocketClient: Ping failed (\(error.localizedDescription)) — marking error")
                }
                #endif
                Task { @MainActor in
                    self?.connectionState = .error
                }
            }
        }
    }
    
    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            switch result {
            case .failure(let error):
                if self?.isClosing == false {
                    #if DEBUG
                    // Reduce error spam - log less frequently
                    if self?.shouldLogClosed() == true {
                        print("WebSocket receive failure: \(error.localizedDescription)")
                    }
                    #endif
                    Task { @MainActor in
                        self?.connectionState = .error
                        self?.lastError = error.localizedDescription
                    }
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    // Only log occasionally to avoid flooding the console during high-frequency events
                    #if DEBUG
                    if self?.shouldLogReceive() == true {
                        print("WebSocketClient [\(self?.url?.lastPathComponent ?? "root")]: Received: \(text.prefix(80))")
                    }
                    #endif
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
            #if DEBUG
            if shouldLogConnect() {
                print("WebSocketClient: Connected to \(url?.absoluteString ?? "unknown")")
            }
            #endif
        }
        startPingTimer()
        DispatchQueue.main.async { self.connectionState = .connected }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stopPingTimer()
        if !isClosing {
            #if DEBUG
            if shouldLogClosed() {
                print("WebSocketClient: Closed with code \(closeCode)")
            }
            #endif
        }
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stopPingTimer()
        if let error = error {
            #if DEBUG
            if shouldLogClosed() {
                print("WebSocketClient: Completed with error: \(error.localizedDescription)")
            }
            #endif
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
    private var activeSubscriptions: [String: String] = [:] // [RelayURL: SubID]
    private var cancellables = Set<AnyCancellable>()
    private let processingQueue = DispatchQueue(label: "com.haven.nostr-processing", qos: .userInitiated)
    
    // Batching events from background to main thread
    private var pendingEvents: [NostrEvent] = []  // guarded by processingQueue
    private var pendingMedia: [MediaItem] = []     // guarded by processingQueue
    private var eventFlushScheduled = false         // guarded by processingQueue
    private var profilesDirty = false
    
    // Batching updates to the UI
    private let eventUpdateSubject = PassthroughSubject<Void, Never>()
    
    // Pagination tracking
    private var activeSubscriptionCount = 0
    private var profilesInFlight = Set<String>()
    private var profileFetchQueue = Set<String>()
    private var profileFlushCancellable: AnyCancellable?
    
    // Used to distinguish live incoming events from historical backfill on startup.
    // Only events newer than this date fire push notifications.
    // Reset each time the app wakes from a silent push so fresh events are "new".
    var sessionStartDate: Date = Date()
    
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
            #if DEBUG
            print("NostrService: Owner Hex Pubkey: \(hex)")
            #endif
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
        
        #if DEBUG
        print("NostrService: Batch fetching metadata for \(pubkeys.count) pubkeys from \(relays.count) Blastr relays")
        #endif
        
        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }
        
        for url in uniqueRelays {
            let client = WebSocketClient()
            client.isTemporary = true
            
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: url.absoluteString)
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
            #if DEBUG
            print("NostrService: Loaded \(profileNames.count) names and \(profilePictures.count) pictures from cache")
            #endif
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
        activeSubscriptions.removeAll()
        cancellables.removeAll()
        // Clear buffered events so stale data isn't flushed after reconnect
        processingQueue.async { [weak self] in
            self?.pendingEvents.removeAll()
            self?.pendingMedia.removeAll()
            self?.eventFlushScheduled = false
        }
        setupThrottling()
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
    ///   - password: Optional password for NIP-49 encrypted keys. Required if using ncryptsec.
    /// - Returns: The signed NostrEvent, or nil if signing fails
    func signEvent(kind: Int, content: String, tags: [[String]] = [], password: String? = nil) -> NostrEvent? {
        var sk: String?

        // Try NIP-49 decryption if ncryptsec exists and password is provided
        let config = ConfigService.shared.config
        if !config.ownerNcryptsec.isEmpty, let pwd = password {
            do {
                let nsec = try config.getDecryptedNsec(password: pwd)
                sk = try config.getDecryptedHexKey(password: pwd)
            } catch {
                #if DEBUG
                print("Failed to decrypt NIP-49 key: \(error.localizedDescription)")
                #endif
                return nil
            }
        } else {
            // Fallback to plaintext ownerHexKey (backward compatibility)
            sk = config.ownerHexKey
        }

        guard let sk = sk else {
            #if DEBUG
            print("NostrService: Cannot sign - no private key available")
            #endif
            return nil
        }
        
        let eventDict: [String: Any] = [
            "pubkey": ownerHexPubkey,
            "created_at": Int64(Date().timeIntervalSince1970),
            "kind": kind,
            "content": content,
            "tags": tags
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }
              
        // Call Go backend for signing
        guard let signedCStr = SignEventC(UnsafeMutablePointer(mutating: (jsonStr as NSString).utf8String), UnsafeMutablePointer(mutating: (sk as NSString).utf8String)) else { return nil }
        
        let signedJsonStr = String(cString: signedCStr)
        free(signedCStr)
        
        guard let signedData = signedJsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NostrEvent.self, from: signedData)
    }
    
    /// Posts an event to the local relay
    func postEvent(_ event: NostrEvent) {
        let msg = ["EVENT", [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ] as [String : Any]] as [Any]
        
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
              
        let localURL = URL(string: ConfigService.shared.config.nostrURL)!
        let client = WebSocketClient()
        client.isTemporary = true
        
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    client.send(text: str)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        client.disconnect()
                    }
                }
            }
            .store(in: &cancellables)
            
        client.connect(url: localURL)
    }
    
    func fetchNotes(from relayURLs: [URL], until: Int64? = nil) {
        DispatchQueue.main.async { 
            self.isFetching = true 
            self.activeSubscriptionCount = relayURLs.count
        }
        for url in relayURLs {
            let urlString = url.absoluteString
            
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
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)
            
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    guard let self = self else { return }
                    self.updateAggregatedStatus()
                    if state == .connected {
                        self.sendRequest(to: client!, url: url, until: until)
                    } else if state == .error {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self = self else { return }
                            guard self.clients[urlString] != nil else { return }
                            #if DEBUG
                            print("NostrService: Reconnecting to \(urlString) after error")
                            #endif
                            self.fetchNotes(from: [url], until: until)
                        }
                    }
                }
                .store(in: &cancellables)
            
            client.connect(url: url)
        }
    }

    
    private func sendRequest(to client: WebSocketClient, url: URL, until: Int64? = nil) {
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

        var filter: [String: Any] = [
            "limit": isHistorical ? 100 : 500,
            "kinds": [0, 1, 6, 1063]
        ]
        if let until = until {
            filter["until"] = until
        }
        
        let req = ["REQ", subscriptionId, filter] as [Any]
        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            #if DEBUG
            print("NostrService: Sending REQ (\(subscriptionId)) to \(url.absoluteString)")
            #endif
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
                self.activeSubscriptionCount -= 1
                if self.activeSubscriptionCount <= 0 {
                    self.isFetching = false
                    self.activeSubscriptionCount = 0
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
                            // Mark dirty — profiles will be saved at the 0.5s flush interval
                            // instead of writing to disk on every single profile update.
                            self?.profilesDirty = true
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
            
            // Buffer events on the processing queue, then batch-flush to main thread.
            // This avoids dispatching a DispatchQueue.main.async for every single event.
            self.pendingEvents.append(event)
            if !items.isEmpty {
                self.pendingMedia.append(contentsOf: items)
            }
            
            // Schedule a single flush if one isn't already pending
            if !self.eventFlushScheduled {
                self.eventFlushScheduled = true
                self.processingQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self = self else { return }
                    let eventsToFlush = self.pendingEvents
                    let mediaToFlush = self.pendingMedia
                    self.pendingEvents.removeAll(keepingCapacity: true)
                    self.pendingMedia.removeAll(keepingCapacity: true)
                    self.eventFlushScheduled = false
                    
                    guard !eventsToFlush.isEmpty else { return }
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        self.events.append(contentsOf: eventsToFlush)
                        if !mediaToFlush.isEmpty {
                            self.noteMedia.append(contentsOf: mediaToFlush)
                        }
                        
                        // Sort & cap less frequently — only every 100 events
                        if self.events.count % 100 < eventsToFlush.count {
                            self.events.sort(by: { $0.created_at > $1.created_at })
                            if self.events.count > 10000 {
                                self.events = Array(self.events.prefix(10000))
                            }
                        }
                        
                        // Save profiles if dirty
                        if self.profilesDirty {
                            self.profilesDirty = false
                            self.saveProfiles()
                        }
                        
                        // Signal UI update — throttled by the 250ms eventUpdateSubject
                        self.eventUpdateSubject.send()
                    }
                }
            }
        }
    }

    
    func fetchCount(from relayURLs: [URL], filter: [String: Any] = [:]) async -> Int? {
        #if DEBUG
        print("NostrService: Starting aggregate fetchCount for \(relayURLs.count) relays")
        #endif
        var totalCount: Int? = nil
        
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
                            .filter { $0.contains(subscriptionId) }
                            .first()
                            .timeout(.seconds(10), scheduler: DispatchQueue.main)
                            .sink { completion in
                                if !hasResumed {
                                    hasResumed = true
                                    if case .failure = completion {
                                        #if DEBUG
                                        print("NostrService [\(relayTag)]: COUNT response timeout")
                                        #endif
                                    } else {
                                        #if DEBUG
                                        print("NostrService [\(relayTag)]: Message stream finished before COUNT")
                                        #endif
                                    }
                                    continuation.resume(returning: nil)
                                }
                            } receiveValue: { msg in
                                if !hasResumed {
                                    hasResumed = true
                                    #if DEBUG
                                    print("NostrService [\(relayTag)]: Received response: \(msg.prefix(200))")
                                    #endif
                                    
                                    if let data = msg.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                       json.count >= 3,
                                       let result = json[2] as? [String: Any],
                                       let count = (result["count"] as? Int) ?? (result["count"] as? NSNumber)?.intValue {
                                        continuation.resume(returning: count)
                                    } else {
                                        #if DEBUG
                                        print("NostrService [\(relayTag)]: Failed to parse COUNT JSON")
                                        #endif
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
                }
            }
        }
        
        #if DEBUG
        print("NostrService: Final aggregated count: \(String(describing: totalCount))")
        #endif
        return totalCount
    }

    private static func mimeFromExtension(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return nil
        }
    }

    private nonisolated static func mediaTypeFromMime(_ mime: String?, url: URL) -> MediaItem.MediaType {
        if let mime = mime?.lowercased() {
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime.hasPrefix("image/") { return .image }
            if mime != "application/octet-stream" { return .unknown }
        }
        // Fallback to extension-based detection
        if url.isVideo { return .video }
        if url.isAudio { return .audio }
        return .image
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

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
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
    
    // Cache for temporary playback URLs (symlinks)
    private var playableURLs: [URL: URL] = [:]
    private let playableLock = NSLock()
    
    private let cacheDirectory: URL
    private var inFlightDownloads: [String: [CheckedContinuation<Data?, Never>]] = [:]
    private let downloadLock = NSLock()
    
    let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheDownloadQueue"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    
    // Throttling for CPU-intensive thumbnail generation
    let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheThumbnailQueue"
        queue.maxConcurrentOperationCount = 2 // Limit concurrent AVAssetImageGenerator instances
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
            #if DEBUG
            print("MediaCacheService: Skipping cache for \(url.absoluteString) - data too small (\(data.count) bytes)")
            #endif
            return
        }
        
        let path = cachePath(for: url)
        do {
            try data.write(to: path)
            #if DEBUG
            print("MediaCacheService: Cached \(url.lastPathComponent) to \(path.path)")
            #endif
        } catch {
            #if DEBUG
            print("MediaCacheService: Failed to cache \(url.absoluteString): \(error.localizedDescription)")
            #endif
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
    
    /// Ensures the local file has a proper extension for AVFoundation playback.
    /// If the file is extensionless (Blossom), creates a temporary symlink with .mp4 extension.
    func preparePlayableURL(for url: URL) -> URL? {
        guard let localURL = internalLocalFileURL(for: url) else { return nil }
        
        // If it already has an extension, we're good
        if !localURL.pathExtension.isEmpty {
            return localURL
        }
        
        playableLock.lock()
        defer { playableLock.unlock() }
        
        if let existingInfo = playableURLs[localURL], FileManager.default.fileExists(atPath: existingInfo.path) {
            return existingInfo
        }
        
        // Create a temp symlink with .mp4 extension
        let tempDir = FileManager.default.temporaryDirectory
        let symlinkName = localURL.lastPathComponent + ".mp4"
        let symlinkURL = tempDir.appendingPathComponent(symlinkName)
        
        do {
            // Remove existing if any
            if FileManager.default.fileExists(atPath: symlinkURL.path) {
                try FileManager.default.removeItem(at: symlinkURL)
            }
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: localURL)
            playableURLs[localURL] = symlinkURL
            #if DEBUG
            print("MediaCacheService: Created playable symlink at \(symlinkURL.path)")
            #endif
            return symlinkURL
        } catch {
            #if DEBUG
            print("MediaCacheService: Failed to create symlink: \(error)")
            #endif
            return localURL // Fallback to original
        }
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
                #if DEBUG
                print("MediaCacheService: Failed to fetch local URL \(url.absoluteString): \(error.localizedDescription)")
                #endif
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
                
                #if DEBUG
                print("MediaCacheService: Starting download for \(filename) (URL: \(url.absoluteString))")
                #endif
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
    
    func generateThumbnail(for url: URL) async -> PlatformImage? {
        // Resolve local file first to see if we can just use it directly
        // This is important for "Local" (Blossom) files where preparePlayableURL might try to make a symlink
        let resolvedURL = self.localFileURL(for: url)
        
        return await withCheckedContinuation { continuation in
            let operation = BlockOperation {
                // 2. Prepare playable URL (handling symlinks if needed)
                let playableURL = self.preparePlayableURL(for: url) ?? resolvedURL ?? url
                
                // 3. Generate
                let asset = AVAsset(url: playableURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400)
                
                let time = CMTime(seconds: 0.1, preferredTimescale: 60)
                
                do {
                     let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                     let image = PlatformImage(cgImage: cgImage, size: .zero)
                     continuation.resume(returning: image)
                } catch {
                     #if DEBUG
                     print("MediaCacheService: Thumbnail generation failed for \(url.lastPathComponent): \(error)")
                     #endif
                     continuation.resume(returning: nil)
                }
            }
            
            self.thumbnailQueue.addOperation(operation)
        }
    }
    
    func updateLocalHost(_ host: String) {
        hostLock.lock()
        defer { hostLock.unlock() }
        self.localHost = host.lowercased()
        #if DEBUG
        print("MediaCacheService: Updated local host to \(self.localHost)")
        #endif
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
            #if DEBUG
            print("MediaCacheService: Cleared \(deletedCount) cached files (Blossom data preserved)")
            #endif
        } catch {
            #if DEBUG
            print("MediaCacheService: Failed to clear cache: \(error.localizedDescription)")
            #endif
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

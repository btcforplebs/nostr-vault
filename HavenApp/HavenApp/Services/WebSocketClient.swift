import Foundation
import Combine
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Darwin

/// URLSessionDelegate that trusts self-signed certificates for localhost
class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    private func isLocalhost(_ host: String?) -> Bool {
        guard let host = host else { return false }
        // Match localhost, 127.0.0.1, ::1, and [::1] (IPv6)
        return host == "localhost" ||
               host == "127.0.0.1" ||
               host == "::1" ||
               host == "[::1]"
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        let authMethod = challenge.protectionSpace.authenticationMethod

        // Only trust self-signed certs for localhost
        if isLocalhost(host) {
            // For server trust challenges (TLS/SSL), accept self-signed certificates
            if authMethod == NSURLAuthenticationMethodServerTrust {
                if let serverTrust = challenge.protectionSpace.serverTrust {
                    // For localhost, always trust self-signed certificates
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                    return
                }
            }
        }

        // For remote servers or other challenges, use default validation
        completionHandler(.performDefaultHandling, nil)
    }
}

/// Centralized service for media loading with proper certificate handling for localhost
class MediaSessionService {
    static let shared = MediaSessionService()

    private let localhostDelegate: LocalhostTrustDelegate
    let session: URLSession

    private init() {
        // Configure session with timeouts suitable for media downloads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60  // 60 seconds for individual requests
        config.timeoutIntervalForResource = 600  // 10 minutes for full resource
        config.waitsForConnectivity = true

        // Create delegate that trusts self-signed certs for localhost
        self.localhostDelegate = LocalhostTrustDelegate()
        self.session = URLSession(configuration: config, delegate: localhostDelegate, delegateQueue: nil)
    }
}

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
        let delegate = LocalhostTrustDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    
    func connect(url: URL) {
        self.url = url
        disconnect()
        
        if !isTemporary {
            #if DEBUG
            print("WebSocketClient: Connecting to \(url.absoluteString)")
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
        
        // Track last connect log to avoid spamming (for reconnect scenarios)
        lastConnectLog = Date()
    }
    
    // Throttle logging to prevent spam during high-frequency events
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
    
    // Relay List Metadata Cache (Kind 10002)
    @Published var relayLists: [String: [String]] = [:] // [Pubkey: [InboxRelayURLs]]
    private var relaysInFlight = Set<String>()
    
    // Batching updates to the UI
    private let eventUpdateSubject = PassthroughSubject<Void, Never>()

    // Buffered event batching — avoids per-event main thread dispatch
    private var eventBuffer: [(NostrEvent, [MediaItem])] = []
    private let bufferLock = NSLock()
    private var bufferFlushTimer: Timer?

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
        
        // Handle npub changes (e.g. after setup)
        ConfigService.shared.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateOwnerHex()
            }
            .store(in: &cancellables)
    }
    
    @Published var profiles: [String: FeedProfile] = [:]
    private(set) var ownerHexPubkey: String = ""
    
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
        }
    }
    
    private func loadProfiles() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let profileURL = havenDir.appendingPathComponent("profiles.json")
        
        if let data = try? Data(contentsOf: profileURL),
           let loaded = try? JSONDecoder().decode([String: FeedProfile].self, from: data) {
            self.profiles = loaded
            #if DEBUG
            print("NostrService: Loaded \(profiles.count) profiles from cache")
            #endif
        }
        
        // Load Relay Lists
        let relayListsURL = havenDir.appendingPathComponent("relay_lists.json")
        if let data = try? Data(contentsOf: relayListsURL),
           let loaded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.relayLists = loaded
            #if DEBUG
            print("NostrService: Loaded \(relayLists.count) relay lists from cache")
            #endif
        }
    }

    
    // Unified cache structure
    private var lastProfileSave: Date = .distantPast
    private let profileSaveThrottle: TimeInterval = 5.0

    private func saveProfilesThrottled() {
        let now = Date()
        if now.timeIntervalSince(lastProfileSave) > profileSaveThrottle {
            lastProfileSave = now
            saveProfiles()
            saveRelayLists()
        }
    }
    
    private func saveRelayLists() {
        let listsCopy = relayLists
        DispatchQueue.global(qos: .utility).async {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
            let relayListsURL = havenDir.appendingPathComponent("relay_lists.json")
            
            if let data = try? JSONEncoder().encode(listsCopy) {
                try? data.write(to: relayListsURL)
            }
        }
    }
    
    private func saveProfiles() {

        let profilesCopy = profiles
        DispatchQueue.global(qos: .utility).async {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
            
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
            let profileURL = havenDir.appendingPathComponent("profiles.json")
            
            if let data = try? JSONEncoder().encode(profilesCopy) {
                try? data.write(to: profileURL)
                #if DEBUG
                // print("NostrService: Saved \(profilesCopy.count) profiles to cache")
                #endif
            }
        }
    }
    
    func fetchMissingProfiles(for pubkeys: [String]) {
        let missing = pubkeys.filter { profiles[$0] == nil && !profilesInFlight.contains($0) }
        guard !missing.isEmpty else { return }
        
        for pubkey in missing {
            profilesInFlight.insert(pubkey)
            profileFetchQueue.insert(pubkey)
            // Also fetch their relay list for smart broadcasting
            fetchRelayList(for: pubkey)
        }
        
        if profileFlushCancellable == nil {
            setupMetadataFlusher()
        }
    }

    
    private func sendProfileRequest(to client: WebSocketClient, pubkeys: [String]) {
        let subscriptionId = "meta-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = [
            "kinds": [0, 10002],
            "authors": pubkeys
        ]
        
        let req = ["REQ", subscriptionId, filter] as [Any]

        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            client.send(text: reqString)
        }
    }
    
    func fetchRelayList(for pubkey: String) {
        guard relayLists[pubkey] == nil && !relaysInFlight.contains(pubkey) else { return }
        relaysInFlight.insert(pubkey)
        
        // Use blastr relays or defaults if empty
        var relays = ConfigService.shared.config.blastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }
        
        #if DEBUG
        print("NostrService: Fetching relay list (10002) for \(pubkey.prefix(8))...")
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
                .sink { state in
                    if state == .connected {
                        let subscriptionId = "relays-\(UUID().uuidString.prefix(8))"
                        let filter: [String: Any] = [
                            "kinds": [10002],
                            "authors": [pubkey],
                            "limit": 1
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
        }
    }
    
    func resetConnections() {
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
        activeSubscriptions.removeAll()
        cancellables.removeAll()
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil
        bufferLock.lock()
        eventBuffer.removeAll()
        bufferLock.unlock()
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
    ///   - password: Optional password for NIP-49 encrypted keys. If not provided, will attempt to retrieve from Keychain.
    /// - Returns: The signed NostrEvent, or nil if signing fails
    func signEvent(kind: Int, content: String, tags: [[String]] = [], password: String? = nil) -> NostrEvent? {
        var sk: String?

        // Try NIP-49 decryption if ncryptsec exists
        let config = ConfigService.shared.config
        if !config.ownerNcryptsec.isEmpty {
            // Use provided password, or try to get from Keychain
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
            // Fallback to plaintext ownerHexKey (backward compatibility)
            sk = config.ownerHexKey
        }

        guard let sk = sk, !sk.isEmpty else {
            print("NostrService: Cannot sign - no private key available (ncryptsec empty=\(config.ownerNcryptsec.isEmpty), nsec empty=\(config.ownerNsec.isEmpty))")
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
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            print("NostrService: Failed to serialize event to JSON")
            return nil
        }

        // Call Go backend for signing
        guard let signedCStr = SignEventC(UnsafeMutablePointer(mutating: (jsonStr as NSString).utf8String), UnsafeMutablePointer(mutating: (sk as NSString).utf8String)) else {
            print("NostrService: SignEventC returned nil (Go signing failed)")
            return nil
        }

        let signedJsonStr = String(cString: signedCStr)
        free(signedCStr)

        guard let signedData = signedJsonStr.data(using: .utf8) else {
            print("NostrService: Failed to convert signed JSON to Data")
            return nil
        }

        do {
            return try JSONDecoder().decode(NostrEvent.self, from: signedData)
        } catch {
            print("NostrService: Failed to decode signed event: \(error) — JSON: \(signedJsonStr.prefix(200))")
            return nil
        }
    }
    
    /// Posts an event to the local relay and broadcasts to configured relays
    func postEvent(_ event: NostrEvent) {
        // Update local state immediately for instant feedback
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.seenEventIds.contains(event.id) {
                self.seenEventIds.insert(event.id)
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
              
        // 1. Post to local relay
        let localURL = URL(string: ConfigService.shared.config.nostrURL)!
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

        // 2. Broadcast to Blastr relays
        let blastrRelays = ConfigService.shared.config.blastrRelays
        if !blastrRelays.isEmpty {
            for relayURLString in blastrRelays {
                guard let url = URL(string: relayURLString) else { continue }
                let broadcastClient = WebSocketClient()
                broadcastClient.isTemporary = true

                broadcastClient.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        if state == .connected {
                            #if DEBUG
                            print("NostrService: Broadcasting event \(event.id.prefix(8)) to \(relayURLString)")
                            #endif
                            broadcastClient.send(text: str)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                broadcastClient.disconnect()
                            }
                        }
                    }
                    .store(in: &cancellables)
                
                broadcastClient.connect(url: url)
            }
        }

        // 3. Smart Broadcast: Send to author's inbox relays if it's a reply or reaction
        if event.kind == 1 || event.kind == 6 || event.kind == 7 {
            // Find target author's pubkey from 'p' tags (skipping own pubkey)
            let targetPubkey = event.tags.first { $0.count >= 2 && $0[0] == "p" && $0[1] != ownerHexPubkey }?[1]
            
            if let targetPubkey = targetPubkey, let targetRelays = relayLists[targetPubkey] {
                #if DEBUG
                print("NostrService: Smart broadcast event \(event.id.prefix(8)) to \(targetPubkey.prefix(8))'s inbox relays: \(targetRelays)")
                #endif
                
                for relayURLString in targetRelays {
                    // Skip if already sent to this relay via blastr
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
                }
            } else if let targetPubkey = targetPubkey {
                // We don't have their relays yet, fetch for next time
                fetchRelayList(for: targetPubkey)
            }
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

        guard let signed = signEvent(kind: 1984, content: description ?? "Reported for \(reason)", tags: tags) else {
            print("NostrService: Failed to sign reporting event")
            return
        }
        
        postEvent(signed)
        #if DEBUG
        print("NostrService: Posted Kind 1984 report for event \(eventId)")
        #endif
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

        guard let signed = signEvent(kind: 1984, content: description ?? "Reported user for \(reason)", tags: tags) else {
            print("NostrService: Failed to sign user reporting event")
            return
        }
        
        postEvent(signed)
        #if DEBUG
        print("NostrService: Posted Kind 1984 report for user \(pubkey)")
        #endif
    }
    
    // Per-relay reconnection state to implement exponential backoff
    private var relayReconnectAttempts: [String: Int] = [:]
    private var relayLastReconnectTime: [String: Date] = [:]
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 2.0
    private let maxReconnectDelay: TimeInterval = 30.0  // Cap at 30s instead of 60s to reduce freeze perception
    
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
    
    func fetchNotes(from relayURLs: [URL], until: Int64? = nil, authors: [String]? = nil) {
        DispatchQueue.main.async {
            self.isFetching = true
            self.activeSubscriptionCount = relayURLs.count
        }
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
                    sendRequest(to: existing, url: url, until: until, authors: authors)
                    continue
                } else if existing.connectionState == .connecting {
                    continue
                }
            }
            
            // Check if we should delay reconnect (exponential backoff)
            if let lastAttempt = relayLastReconnectTime[urlString],
               let attempts = relayReconnectAttempts[urlString] {
                let delay = min(self.baseReconnectDelay * pow(2.0, Double(attempts)), self.maxReconnectDelay)
                let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
                
                if timeSinceLastAttempt < delay {
                    #if DEBUG
                    print("NostrService: Skipping reconnect to \(urlString) - backing off (\(attempts) attempts, \(delay - timeSinceLastAttempt)s remaining)")
                    #endif
                    // Schedule retry after backoff delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + (delay - timeSinceLastAttempt)) { [weak self] in
                        guard let self = self else { return }
                        guard self.clients[urlString] != nil else { return }
                        self.fetchNotes(from: [url], until: until, authors: authors)
                    }
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
                        // Reset backoff on successful connection
                        self.relayReconnectAttempts[urlString] = 0
                        self.sendRequest(to: client!, url: url, until: until, authors: authors)
                    } else if state == .error {
                        // Increment backoff counter
                        let attempts = (self.relayReconnectAttempts[urlString] ?? 0) + 1
                        self.relayReconnectAttempts[urlString] = attempts
                        self.relayLastReconnectTime[urlString] = Date()
                        
                        // Check if we've exceeded max attempts - stop hammering
                        if attempts > self.maxReconnectAttempts {
                            #if DEBUG
                            print("NostrService: Max reconnect attempts reached for \(urlString), giving up")
                            #endif
                            return
                        }
                        
                        // Calculate exponential backoff delay
                        let delay = min(self.baseReconnectDelay * pow(2.0, Double(attempts - 1)), self.maxReconnectDelay)
                        
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
        }
    }

    
    private func sendRequest(to client: WebSocketClient, url: URL, until: Int64? = nil, authors: [String]? = nil) {
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
            "limit": isHistorical ? 100 : 200,
            "kinds": [0, 1, 3, 4, 6, 7, 1063, 30023, 9735]
        ]
        if let until = until {
            filter["until"] = until
        }
        
        // If we have followed authors, we fetch their notes
        var filters: [[String: Any]] = [filter]
        if let authors = authors, !authors.isEmpty {
            filters[0]["authors"] = authors
        }
        
        // CRITICAL: Always subscribe to mentions (#p) of the owner so "tagged notes" 
        // from people we don't follow still show up in the viewer.
        let ownerHex = self.ownerHexPubkey
        if !ownerHex.isEmpty {
            var mentionsFilter = filter
            mentionsFilter["#p"] = [ownerHex]
            filters.append(mentionsFilter)
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
                // Flush any buffered events before marking EOSE complete
                self.flushEventBuffer()
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
                    let name = metadata["name"] as? String
                    let displayName = metadata["display_name"] as? String
                    let picture = (metadata["picture"] as? String).flatMap { URL(string: $0) }
                    let nip05 = metadata["nip05"] as? String
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        var profile = self.profiles[event.pubkey] ?? FeedProfile(pubkey: event.pubkey)
                        
                        var changed = false
                        if profile.name != name {
                            profile.name = name
                            changed = true
                        }
                        if profile.displayName != displayName {
                            profile.displayName = displayName
                            changed = true
                        }
                        if profile.pictureURL != picture {
                            profile.pictureURL = picture
                            changed = true
                        }
                        if profile.nip05 != nip05 {
                            profile.nip05 = nip05
                            changed = true
                        }
                        
                        if changed {
                            self.profiles[event.pubkey] = profile
                            self.profilesInFlight.remove(event.pubkey)
                            self.saveProfilesThrottled()
                            self.eventUpdateSubject.send()
                        }
                    }
                }
                return // Metadata doesn't need to be in the events list
            }
            
            if event.kind == 10002 {
                // Handling Kind 10002 (Relay List Metadata)
                // NIP-65: ["r", relay_url, "read" | "write"]
                var inboxRelays: [String] = []
                for tag in event.tags {
                    if tag.count >= 2 && tag[0] == "r" {
                        let url = tag[1]
                        let type = tag.count >= 3 ? tag[2] : ""
                        
                        // "read" means this is where the user RECEIVES notes (inbox)
                        // If no type is specified, it's both read and write
                        if type == "read" || type == "" {
                            inboxRelays.append(url)
                        }
                    }
                }
                
                if !inboxRelays.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.relayLists[event.pubkey] = inboxRelays
                        self.relaysInFlight.remove(event.pubkey)
                        self.saveProfilesThrottled()
                        #if DEBUG
                        print("NostrService: Cached \(inboxRelays.count) inbox relays for \(event.pubkey.prefix(8))")
                        #endif
                    }


                }
                return
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

            // Buffer event instead of dispatching to main thread per-event
            bufferLock.lock()
            eventBuffer.append((event, items))
            bufferLock.unlock()
            scheduleBufferFlush()
        }
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
        
        if events.count > 10000 {
            events = Array(events.prefix(10000))
        }
        eventUpdateSubject.send()
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

// MARK: - TLS Trust Bypass for Local Relay

/// A URLSession wrapper that bypasses TLS certificate verification for localhost/127.0.0.1.
/// This is necessary because the local Haven relay uses a self-signed certificate.
class TLSSkipSession: NSObject, URLSessionDelegate {
    static let shared: URLSession = {
        let delegate = TLSSkipSession()
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
    
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // If the host is local, we allow the self-signed certificate
        if let host = challenge.protectionSpace.host.lowercased() as String?,
           host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        
        // Otherwise, use default handling
        completionHandler(.performDefaultHandling, nil)
    }
}

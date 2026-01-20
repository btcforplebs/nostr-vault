import Foundation
import Combine
import SwiftUI
import CryptoKit

class WebSocketClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    enum ConnectionState: String {
        case disconnected
        case connecting
        case connected
        case error
    }

    private var webSocketTask: URLSessionWebSocketTask?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var lastError: String?
    let messageSubject = PassthroughSubject<String, Never>()
    
    private var url: URL?
    
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config)
    }()
    
    func connect(url: URL) {
        self.url = url
        disconnect()
        
        print("WebSocketClient: Connecting to \(url.absoluteString)")
        DispatchQueue.main.async {
            self.connectionState = .connecting
            self.lastError = nil
        }
        
        let task = Self.session.webSocketTask(with: url)
        task.delegate = self
        webSocketTask = task
        task.resume()
        receiveMessage()
    }
    
    func disconnect() {
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
                print("WebSocket receive failure: \(error.localizedDescription)")
                DispatchQueue.main.async { 
                    self?.connectionState = .error
                    self?.lastError = error.localizedDescription
                }
            case .success(let message):
                switch message {
                case .string(let text):
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
        print("WebSocketClient: Connected to \(url?.absoluteString ?? "unknown")")
        DispatchQueue.main.async { self.connectionState = .connected }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("WebSocketClient: Closed with code \(closeCode)")
        DispatchQueue.main.async { self.connectionState = .disconnected }
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

class NostrService: ObservableObject {
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
    
    init() {
        setupThrottling()
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
        DispatchQueue.main.async { self.isFetching = true }
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
        // Reverted to 500 as requested for better stability.
        var filter: [String: Any] = ["limit": 500]
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
                    self?.isFetching = false
                    self?.events.sort(by: { $0.created_at > $1.created_at })
                    self?.eventUpdateSubject.send()
                }
            }
        }

        if type != "EVENT" { return }
        
        guard json.count >= 3 else { return }
        
        if let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
            
            if seenEventIds.contains(event.id) { return }
            seenEventIds.insert(event.id)
            
            var items: [MediaItem] = []
            
            if event.kind == 1063 {
                // Parse KIND 1063 url tag
                if let urlTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "url" }),
                   let url = URL(string: urlTag[1]) {
                    let mediaType: MediaItem.MediaType = url.isVideo ? .video : .image
                    items.append(MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate))
                }
            } else {
                let urls = extractMediaURLs(from: event.content)
                items = urls.map { url in
                    let mediaType: MediaItem.MediaType = url.isVideo ? .video : .image
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate)
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
    
    func extractMediaURLs(from content: String) -> [URL] {
        // More robust pattern for media URLs, including those without extensions but following common patterns
        let pattern = #"(https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic|tiff)(?:\?\S+)?)|(https?://\S+?/blossom/[a-f0-9]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let nsString = content as NSString
        let results = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsString.length))
        
        return results.compactMap { result in
            let urlString = nsString.substring(with: result.range)
            guard var url = URL(string: urlString) else { return nil }
            
            // Normalize localhost URLs to use HTTP instead of HTTPS
            // The local Blossom server only serves over HTTP, not HTTPS
            if url.scheme == "https" && (url.host == "localhost" || url.host == "127.0.0.1") {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.scheme = "http"
                if let normalizedURL = components?.url {
                    url = normalizedURL
                }
            }
            
            return url
        }
    }
}

class MediaCacheService: ObservableObject {
    static let shared = MediaCacheService()
    
    private let cacheDirectory: URL
    let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheDownloadQueue"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cacheDirectory = home.appendingPathComponent("haven_relay/cache")
        
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
        let path = cachePath(for: url)
        do {
            try data.write(to: path)
            print("MediaCacheService: Cached \(url.lastPathComponent) to \(path.path)")
        } catch {
            print("MediaCacheService: Failed to cache \(url.absoluteString): \(error.localizedDescription)")
        }
    }
    
    func loadFromCache(url: URL) -> Data? {
        let path = cachePath(for: url)
        return try? Data(contentsOf: path)
    }
    
    private func hash(url: URL) -> String {
        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    enum MediaSource: String {
        case blossom = "Local"
        case cached = "Cached"
        case remote = "Remote"
        
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
    
    func getSource(for url: URL) -> MediaSource {
        if url.host == "127.0.0.1" || url.host == "localhost" {
            return .blossom
        } else if isCached(url: url) {
            return .cached
        } else {
            return .remote
        }
    }
}

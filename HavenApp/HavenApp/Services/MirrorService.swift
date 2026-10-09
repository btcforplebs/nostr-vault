import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Service that mirrors owner media from external Blossom servers to local storage.
///
/// Provides published state for UI observation in RelayStatusSheet and SettingsView.
@MainActor
class MirrorService: ObservableObject {
    static let shared = MirrorService()

    // MARK: - Published State
    enum MirrorState: Equatable {
        case idle
        case mirroring
        case complete
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: String
        let message: String
    }

    @Published var state: MirrorState = .idle
    @Published var progress: (completed: Int, total: Int)?
    @Published var statusText: String = ""
    @Published var lastResult: String = ""
    @Published var lastMirrorDate: Date?
    @Published var logEntries: [LogEntry] = []

    private func log(_ message: String, level: String = "INFO") {
        logEntries.append(LogEntry(timestamp: Date(), level: level, message: message))
        // Cap at 500 entries
        if logEntries.count > 500 {
            logEntries.removeFirst(logEntries.count - 500)
        }
    }

    // MARK: - Public API

    /// Run mirror operation using provided services.
    func runMirror(configService: ConfigService, nostrService: NostrService) {
        guard state != .mirroring else { return }

        state = .mirroring
        progress = nil
        statusText = "Starting..."
        logEntries = []
        log("Starting Blossom mirror operation...")

        Task {
            // Request background execution time on iOS so the mirror completes
            // even if the user switches apps mid-operation.
            #if os(iOS)
            let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "BlossomMirrorSync", expirationHandler: nil)
            #endif
            defer {
                #if os(iOS)
                UIApplication.shared.endBackgroundTask(bgTaskId)
                #endif
                // Guarantee state resets even if the operation fails or is cancelled
                if state == .mirroring {
                    state = .idle
                    progress = nil
                    statusText = ""
                }
            }

            let service = BlossomService(configService: configService, nostrService: nostrService)
            var totalCount = 0

            // 1. Mirror from configured Blossom mirrors (BUD-04 /list endpoint)
            let mirrors = configService.config.activeBlossomMirrors
            if !mirrors.isEmpty {
                log("Found \(mirrors.count) configured mirror(s): \(mirrors.joined(separator: ", "))")
                statusText = "Fetching blob list from mirrors..."
                log("Fetching blob list from mirrors...")
                let count = await service.mirrorAllFromExternal { completed, total in
                    Task { @MainActor in
                        self.progress = (completed, total)
                        self.statusText = "Mirroring from servers: \(completed)/\(total)"
                    }
                } logMessage: { message, level in
                    Task { @MainActor in
                        self.log(message, level: level)
                    }
                }
                log("Mirror from servers complete: \(count) new blob(s) mirrored")
                totalCount += count
            } else {
                log("No external Blossom mirrors configured, skipping server mirror phase")
            }

            // 2. Mirror from note media URLs (handles any server) - includes all historical notes from local relay
            statusText = "Scanning notes for media..."
            log("Scanning local relay for owner media URLs...")
            let ownerMedia = await self.fetchAllOwnerMedia(configService: configService, nostrService: nostrService)
            log("Found \(ownerMedia.count) media URL(s) from notes")

            // Deduplicate combined media by URL
            var seenURLs = Set<URL>()
            var noteMedia: [MediaItem] = []
            for item in ownerMedia {
                if seenURLs.insert(item.url).inserted {
                    noteMedia.append(item)
                }
            }
            if ownerMedia.count != noteMedia.count {
                log("Deduplicated to \(noteMedia.count) unique URL(s)")
            }

            statusText = "Mirroring media from notes (\(noteMedia.count) found)..."
            log("Starting note media mirror (\(noteMedia.count) URLs to check)...")
            let noteCount = await service.mirrorFromNoteMedia(noteMedia) { completed, total in
                Task { @MainActor in
                    self.progress = (completed, total)
                    self.statusText = "Mirroring from notes: \(completed)/\(total)"
                }
            } logMessage: { message, level in
                Task { @MainActor in
                    self.log(message, level: level)
                }
            }
            log("Mirror from notes complete: \(noteCount) new blob(s) mirrored")
            totalCount += noteCount

            // Update final state
            state = .complete
            progress = nil
            statusText = ""
            lastMirrorDate = Date()
            VaultHistory.lastMediaImport = lastMirrorDate
            lastResult = totalCount > 0 ? "Mirrored \(totalCount) files" : "All media already mirrored"
            log(totalCount > 0 ? "Done — mirrored \(totalCount) file(s) to local storage" : "Done — all media already mirrored")

            // Keep state as .complete so the user can review logs and dismiss manually
        }
    }

    /// Extracts media items from active feed notes in FeedService.shared.notes (owner and whitelisted only)

    /// Fetches all historical notes for the owner from the local relay, extracting associated media URLs.
    /// This ensures we discover past uploads that are no longer actively in the feed buffer.
    private func fetchAllOwnerMedia(configService: ConfigService, nostrService: NostrService) async -> [MediaItem] {
        let ownerPubkey = nostrService.ownerHexPubkey
        var items = nostrService.noteMedia
        
        guard !ownerPubkey.isEmpty else { return items }
        let localURLStr = configService.config.nostrURL
        guard let localURL = URL(string: localURLStr) else { return items }
        
        let client = WebSocketClient()
        client.isTemporary = true
        
        // Use holding class to prevent Swift 6 concurrency capture errors
        class CancellableHolder {
            var cancellable: AnyCancellable?
        }
        let holder = CancellableHolder()
        
        // Use AsyncStream to bridge Combine logic cleanly
        let stream = AsyncStream<String> { continuation in
            holder.cancellable = client.messageSubject.sink { msg in
                continuation.yield(msg)
            }
            
            client.connect(url: localURL)
            
            continuation.onTermination = { _ in
                holder.cancellable?.cancel()
                DispatchQueue.main.async { client.disconnect() }
            }
        }
        
        // Wait briefly for WebSocket connection to established
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // Fire REQ for all owner's notes
        let reqId = "mirrorhist"
        let reqFilter: [String: Any] = ["kinds": [1], "authors": [ownerPubkey]]
        let reqMsg = ["REQ", reqId, reqFilter] as [Any]
        
        if let reqData = try? JSONSerialization.data(withJSONObject: reqMsg),
           let reqString = String(data: reqData, encoding: .utf8) {
            client.send(text: reqString)
        }
        
        // Setup a 4 second maximum timeout for historical note fetch
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            return true
        }
        
        var newMedia = [MediaItem]()
        
        for await message in stream {
            if timeoutTask.isCancelled { break }
            if Task.isCancelled { break }

            guard let data = message.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  array.count >= 2,
                  let msgType = array[0] as? String else { continue }
                  
            if msgType == "EOSE" && (array[1] as? String) == reqId {
                timeoutTask.cancel()
                break
            } else if msgType == "EVENT", array.count >= 3,
                      let eventDict = array[2] as? [String: Any],
                      let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
                      let eventRaw = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
                
                let urls = nostrService.extractMediaURLs(from: eventRaw.content)
                let eventItems = urls.map { 
                    MediaItem(id: UUID(), url: $0, type: .unknown, dateAdded: eventRaw.createdAtDate, pubkey: eventRaw.pubkey, tags: eventRaw.tags, mimeType: nil) 
                }
                newMedia.append(contentsOf: eventItems)
            }
        }
        
        timeoutTask.cancel()
        client.disconnect()
        
        items.append(contentsOf: newMedia)
        return items
    }
}

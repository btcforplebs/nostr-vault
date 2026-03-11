import Foundation
import Combine

/// Service that mirrors owner media from external Blossom servers to local storage.
///
/// Follows the same singleton pattern as MacRelaySyncService. Provides published
/// state for UI observation in RelayStatusSheet and SettingsView.
@MainActor
class MirrorService: ObservableObject {
    static let shared = MirrorService()

    // MARK: - Published State
    enum MirrorState: Equatable {
        case idle
        case mirroring
        case complete
    }

    @Published var state: MirrorState = .idle
    @Published var progress: (completed: Int, total: Int)?
    @Published var lastResult: String = ""
    @Published var lastMirrorDate: Date?

    // MARK: - Public API

    /// Run mirror operation using provided services.
    func runMirror(configService: ConfigService, nostrService: NostrService) {
        guard state != .mirroring else { return }

        state = .mirroring
        progress = nil

        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            var totalCount = 0

            // 1. Mirror from configured Blossom mirrors (BUD-04 /list endpoint)
            if !configService.config.blossomMirrors.isEmpty {
                let count = await service.mirrorAllFromExternal { completed, total in
                    Task { @MainActor in
                        self.progress = (completed, total)
                    }
                }
                totalCount += count
            }

            // 2. Mirror from note media URLs (handles any server) - includes all historical notes from local relay
            let noteMedia = await self.fetchAllOwnerMedia(configService: configService, nostrService: nostrService)
            let noteCount = await service.mirrorFromNoteMedia(noteMedia) { completed, total in
                Task { @MainActor in
                    self.progress = (completed, total)
                }
            }
            totalCount += noteCount

            // Update final state
            state = .complete
            progress = nil
            lastMirrorDate = Date()
            lastResult = totalCount > 0 ? "Mirrored \(totalCount) files" : "All media already mirrored"

            // Reset to idle after delay
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if state == .complete {
                state = .idle
            }
        }
    }

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

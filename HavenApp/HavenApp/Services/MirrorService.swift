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

    /// Every one of the owner's notes in the local vault, read page by page
    /// (`OwnerNotePager`): one query used to return only the newest 250, so
    /// media in older notes was never imported. Plus the media already in the feed.
    private func fetchAllOwnerMedia(configService: ConfigService, nostrService: NostrService) async -> [MediaItem] {
        let ownerPubkey = nostrService.ownerHexPubkey
        var items = nostrService.noteMedia

        guard !ownerPubkey.isEmpty else { return items }
        guard let localURL = URL(string: configService.config.nostrURL) else { return items }

        let client = WebSocketClient()
        client.isTemporary = true
        let pages = NotePageReader(client: client)
        client.connect(url: localURL)
        defer { client.disconnect() }
        // Wait briefly for the WebSocket connection to be established
        try? await Task.sleep(nanoseconds: 500_000_000)

        var pageNumber = 0
        let notes = await OwnerNotePager.collect(
            owner: ownerPubkey, id: \.id, pubkey: \.pubkey, createdAt: { Int($0.created_at) }
        ) { until in
            pageNumber += 1
            return await pages.fetch(subscription: "mirrorhist\(pageNumber)", filter: OwnerNotePager.filter(owner: ownerPubkey, until: until))
        }
        log("Read \(notes.count) of your note(s) from this device's vault (\(pageNumber) page(s))")

        for note in notes {
            let urls = nostrService.extractMediaURLs(from: note.content)
            items.append(contentsOf: urls.map {
                MediaItem(id: UUID(), url: $0, type: .unknown, dateAdded: note.createdAtDate, pubkey: note.pubkey, tags: note.tags, mimeType: nil)
            })
        }
        return items
    }
}

/// One REQ at a time over a temporary vault connection: the events of a
/// subscription until its EOSE, or what came within 8 s.
@MainActor
private final class NotePageReader {
    private let client: WebSocketClient
    private var cancellable: AnyCancellable?
    private var waiting: (id: String, events: [NostrEvent], done: CheckedContinuation<[NostrEvent], Never>)?

    init(client: WebSocketClient) {
        self.client = client
        cancellable = client.messageSubject.receive(on: DispatchQueue.main).sink { [weak self] in self?.handle($0) }
    }

    func fetch(subscription id: String, filter: [String: Any]) async -> [NostrEvent] {
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", id, filter] as [Any]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return await withCheckedContinuation { continuation in
            waiting = (id, [], continuation)
            client.send(text: text)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.finish(id)
            }
        }
    }

    private func handle(_ message: String) {
        guard let current = waiting,
              let data = message.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2, let type = array[0] as? String, (array[1] as? String) == current.id else { return }
        if type == "EOSE" || type == "CLOSED" {
            finish(current.id)
        } else if type == "EVENT", array.count >= 3,
                  let dict = array[2] as? [String: Any],
                  let eventData = try? JSONSerialization.data(withJSONObject: dict),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
            waiting?.events.append(event)
        }
    }

    private func finish(_ id: String) {
        guard let current = waiting, current.id == id else { return }
        waiting = nil
        if let data = try? JSONSerialization.data(withJSONObject: ["CLOSE", id]), let text = String(data: data, encoding: .utf8) {
            client.send(text: text)
        }
        current.done.resume(returning: current.events)
    }
}

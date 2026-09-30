import Foundation
import Network
import os.log
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Posts whose media is saved on this device but not yet on any outside
/// Blossom server. See `QueuedMediaPost` for why they wait instead of failing.
///
/// Retries whenever there is a reason to think a server might now answer: the
/// app comes to the foreground, the network changes, and every minute while
/// anything is waiting. The queue is on disk, so a relaunch keeps it.
@MainActor
final class MediaPostQueue: ObservableObject {
    static let shared = MediaPostQueue()

    @Published private(set) var posts: [QueuedMediaPost] = []

    private let logger = Logger(subsystem: "com.bitvora.haven", category: "media-post-queue")
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var isRetrying = false
    private var started = false
    private var lastPathSatisfied: Bool?

    private init() {
        loadFromDisk()
    }

    // MARK: - Lifecycle

    /// Idempotent. Called at launch and on enqueue.
    func start() {
        guard !started else { retryAll(reason: "start"); return }
        started = true

        #if os(iOS)
        let activeName = UIApplication.didBecomeActiveNotification
        #else
        let activeName = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: activeName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retryAll(reason: "foreground") }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let changed = self.lastPathSatisfied != satisfied
                self.lastPathSatisfied = satisfied
                if satisfied && changed { self.retryAll(reason: "network") }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.haven.media-post-queue.path"))

        updateTimer()
        retryAll(reason: "launch")
    }

    private func updateTimer() {
        if posts.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.retryAll(reason: "timer") }
            }
        }
    }

    // MARK: - Queue

    func enqueue(_ post: QueuedMediaPost) {
        posts.append(post)
        saveToDisk()
        log("queued post \(post.id.prefix(8)) with \(post.pendingMedia.count) attachment(s) waiting for an outside server")
        updateTimer()
        start()
    }

    func discard(id: String) {
        posts.removeAll { $0.id == id }
        saveToDisk()
        updateTimer()
        log("discarded waiting post \(id.prefix(8))")
    }

    /// Try every waiting post once. Posts are sent one at a time, oldest first,
    /// so they reach relays in the order they were written.
    func retryAll(reason: String) {
        guard !posts.isEmpty, !isRetrying else { return }
        isRetrying = true
        Task { @MainActor in
            defer { isRetrying = false; updateTimer() }
            log("retrying \(posts.count) waiting post(s) — \(reason)")
            for id in posts.map(\.id) {
                let sent = await attempt(id: id)
                // The servers are the same for every post; if the first could
                // not be hosted, the rest won't be either this round.
                if !sent { break }
            }
        }
    }

    /// One attempt at one post. Returns true if it was sent.
    private func attempt(id: String) async -> Bool {
        guard var post = posts.first(where: { $0.id == id }) else { return true }

        let config = ConfigService.shared.config
        guard config.activeAccountNpub == post.accountNpub else {
            log("waiting post \(id.prefix(8)) belongs to another account — holding it until that account is active")
            return false
        }

        post.attempts += 1
        post.lastAttempt = Date()
        let blossom = BlossomService(configService: ConfigService.shared, nostrService: NostrService.shared)

        for index in post.media.indices where post.media[index].url == nil {
            guard let sha256 = post.media[index].sha256 else { continue }
            guard let url = await blossom.hostLocalBlob(
                sha256: sha256,
                contentType: post.media[index].mimeType ?? "application/octet-stream"
            ) else {
                update(post)
                return false
            }
            post.media[index].url = url.absoluteString
            // Persist each hosted URL at once, so a crash between two
            // attachments doesn't upload the first one again.
            update(post)
        }

        guard let (content, tags) = post.assembled() else {
            update(post)
            return false
        }

        guard let event = await NostrService.shared.mineAndSignEventAsync(
            kind: 1, content: content, tags: tags, difficulty: post.powDifficulty
        ) else {
            log("waiting post \(id.prefix(8)): media is hosted but signing failed — will retry", level: "ERROR")
            update(post)
            return false
        }

        NostrService.shared.postEvent(event)
        FeedService.shared.addNote(FeedNote(
            id: event.id,
            pubkey: event.pubkey,
            content: event.content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
            tags: event.tags,
            kind: event.kind
        ))
        posts.removeAll { $0.id == id }
        saveToDisk()
        log("sent waiting post \(id.prefix(8)) as \(event.id.prefix(8)) after \(post.attempts) attempt(s)")
        ErrorNotificationManager.shared.show(
            "Your waiting post was sent.",
            icon: "checkmark.icloud.fill",
            style: .warning
        )
        return true
    }

    private func update(_ post: QueuedMediaPost) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index] = post
        saveToDisk()
    }

    // MARK: - Disk

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir.appendingPathComponent("queued-media-posts.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            posts = try JSONDecoder().decode([QueuedMediaPost].self, from: data)
        } catch {
            // Never drop a user's post silently: keep the unreadable file aside.
            let aside = Self.fileURL.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: Self.fileURL, to: aside)
            log("could not read the waiting-post queue (\(error.localizedDescription)); kept it at \(aside.lastPathComponent)", level: "ERROR")
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(posts)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            log("could not save the waiting-post queue: \(error.localizedDescription)", level: "ERROR")
        }
    }

    private func log(_ message: String, level: String = "INFO") {
        logger.info("\(message, privacy: .public)")
        RelayProcessManager.shared.addLog("Waiting posts: " + message, level: level)
        print("Waiting posts: \(message)")
    }
}

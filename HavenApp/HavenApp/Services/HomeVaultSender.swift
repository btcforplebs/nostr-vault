#if os(iOS)
import Foundation
import UIKit

/// Sends this phone's own notes and media to a home vault: another of the
/// owner's phones in kiosk mode, reached over the FIPS mesh. The kiosk keeps
/// them and passes notes on to the regular relays.
///
/// The home vault is a kiosk's mesh address, picked from the owner's 10063 or
/// pasted/scanned from the kiosk. This phone lists it in the owner's 10063, so
/// the kiosk needs no key. The kiosk's mesh door takes `PUT /upload` and an
/// outbox websocket at `/`, only for keys its relay lets write, so nothing is
/// sent for any other account.
///
/// Everything still goes to this phone's own relay first; the kiosk gets a
/// copy. What cannot reach it waits in a queue on disk and is sent when the
/// app is open and the kiosk answers. No background modes: iOS suspends the
/// mesh with the app.
@MainActor
final class HomeVaultSender: ObservableObject {
    static let shared = HomeVaultSender()

    @Published private(set) var homeVault: HomeVault?
    @Published private(set) var queue: [HomeVaultItem] = []
    @Published private(set) var sending = false
    @Published private(set) var lastResult: String?

    private static let vaultKey = "homeVault.v1"
    /// A queue that never drains must not grow without bound.
    static let maxQueue = 500
    /// The kiosk's mesh door takes up to 256 MB (#475); larger is not queued.
    static let maxBlobBytes = 256 * 1024 * 1024

    private var retryTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.vaultKey) {
            homeVault = try? JSONDecoder().decode(HomeVault.self, from: data)
        }
        queue = Self.loadQueue()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainSoon() }
        }
        drainSoon()
    }

    // MARK: - Choosing the vault

    /// The owner's own mesh vaults from their 10063, minus this phone's.
    static func meshEntries(serverList: [String]) -> [String] {
        HomeVaultLogic.meshEntries(serverList: serverList, excluding: FipsMeshService.shared.ownMeshNpub)
    }

    func setHomeVault(_ vault: HomeVault?) {
        homeVault = vault
        if let vault, let data = try? JSONEncoder().encode(vault) {
            UserDefaults.standard.set(data, forKey: Self.vaultKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.vaultKey)
        }
        lastResult = nil
        // List it (or stop listing it) in this account's 10063.
        NostrService.shared.publishServerList()
        drainSoon()
    }

    // MARK: - Queueing

    /// A signed event this phone just published. Only the home vault owner's own.
    func enqueue(eventDict: [String: Any]) {
        guard let vault = homeVault,
              let pubkey = eventDict["pubkey"] as? String, pubkey == vault.ownerHex,
              let id = eventDict["id"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: eventDict),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = add(HomeVaultItem(kind: .event, id: id, ownerHex: pubkey, eventJSON: json, contentType: nil, added: Date(), attempts: 0, notBefore: nil))
    }

    /// A blob just saved to this phone's own Blossom, signed for by `signer`.
    /// True when it is queued for the home vault.
    @discardableResult
    func enqueue(blobSha256 sha256: String, contentType: String, signer: String, byteCount: Int) -> Bool {
        guard let vault = homeVault, signer == vault.ownerHex else { return false }
        guard byteCount <= Self.maxBlobBytes else {
            appLog("\(sha256.prefix(8)) is \(byteCount) bytes, over the \(Self.maxBlobBytes) the kiosk takes — kept on this phone only", level: "WARN")
            lastResult = "A file over 256 MB stays on this phone only: the home vault doesn't take files that big."
            return false
        }
        return add(HomeVaultItem(kind: .blob, id: sha256, ownerHex: signer, eventJSON: nil, contentType: contentType, added: Date(), attempts: 0, notBefore: nil))
    }

    /// The public upload of a blob a note names on `server` (kiosk-only
    /// case). Retried until that server has it. False when the queue is full:
    /// the note must then wait instead of naming a link nothing will fill.
    func enqueue(mirrorSha256 sha256: String, contentType: String, signer: String, server: String) -> Bool {
        add(HomeVaultItem(kind: .mirror, id: sha256, ownerHex: signer, eventJSON: nil, contentType: contentType,
                          added: Date(), attempts: 0, notBefore: Date().addingTimeInterval(60), server: server))
    }

    /// Make sure the home vault holds `sha256` now, for a note about to link
    /// it with no public copy yet (Tao: never publish a note that points
    /// nowhere). Bounded: the composer waits at most `timeout`. True once the
    /// vault confirms it, by HEAD or by taking the upload.
    func ensureOnVault(sha256: String, timeout: TimeInterval = 45) async -> Bool {
        guard let vault = homeVault, vault.ownerHex == NostrService.shared.activeHexPubkey else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.confirmOrSend(sha256: sha256, vault: vault) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func confirmOrSend(sha256: String, vault: HomeVault) async -> Bool {
        // The dial first, without holding anything: it is a blocking FFI call
        // the timeout cannot interrupt, and holding `sending` across it would
        // freeze the queue for as long as it takes (Tron, #473).
        guard let base = await FipsMeshService.shared.ingressURL(meshNpub: vault.meshNpub),
              !Task.isCancelled else { return false }
        // A background pass may be sending this very blob: let it finish
        // rather than race it for the vault's one upload slot. ensureOnVault's
        // timeout cancels this wait. No await between the loop and the claim.
        while sending {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return false }
        }
        sending = true
        defer { sending = false }
        if await HomeVaultTransport.vaultHas(sha256: sha256, base: base) { return true }
        // A background pass may hold the item or the vault's one upload slot:
        // then the vault itself is the answer.
        guard let item = queue.first(where: { $0.kind == .blob && $0.id == sha256 }),
              await sendBlob(item, base: base) == .sent else {
            return await HomeVaultTransport.vaultHas(sha256: sha256, base: base)
        }
        appLog("sent blob \(sha256.prefix(8)) before publishing its note")
        remove(item)
        return true
    }

    /// False when the item could not be queued.
    @discardableResult
    private func add(_ item: HomeVaultItem) -> Bool {
        guard !queue.contains(where: { $0.kind == item.kind && $0.id == item.id }) else { return true }
        // Full: refuse the new item, as the kiosk's own queue does. Dropping
        // the oldest would lose something that never got out (Tron, #473).
        guard queue.count < Self.maxQueue else {
            appLog("queue full (\(Self.maxQueue)) — \(item.kind.rawValue) \(item.id.prefix(8)) not queued", level: "WARN")
            lastResult = "The queue is full: new notes and media aren't going to your home vault. Tap Send now when it's in reach."
            return false
        }
        // Media before the notes that point at it, so a note never lands first.
        if let index = HomeVaultLogic.insertionIndex(for: item.kind, in: queue) {
            queue.insert(item, at: index)
        } else {
            queue.append(item)
        }
        saveQueue()
        drainSoon()
        return true
    }

    // MARK: - Sending

    func drainSoon() {
        guard !queue.isEmpty else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        Task { await drain() }
    }

    /// One pass over the queue, oldest first. Each item has its own backoff,
    /// so one that keeps failing does not hold up the rest; a note still waits
    /// while media queued before it has not reached the vault. `userInitiated`
    /// (Send now) ignores the backoff and may ask an external signer.
    func drain(userInitiated: Bool = false) async {
        guard !queue.isEmpty else { return }
        guard !sending else {
            if userInitiated { lastResult = "Already sending…" }
            return
        }
        sending = true
        defer { sending = false }

        // A post made just before leaving the app still gets its window.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "homevault-send") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }

        let now = Date()
        var gaveUp: [String] = []
        for item in queue where HomeVaultLogic.isExpired(item, now: now) {
            appLog("gave up on \(item.kind.rawValue) \(item.id.prefix(8)) after \(item.attempts) tries", level: "WARN")
            gaveUp.append(item.kind == .mirror
                ? "a photo a note links never reached your public server"
                : "a \(item.kind == .event ? "note" : "photo") never reached your home vault")
            remove(item)
        }

        let active = UIApplication.shared.applicationState == .active
        // A bunker signer may need a person: never ask it from the background.
        let signerNeedsPerson = ConfigService.shared.config.activeSigningMode() != "local"
        var base: URL?
        var meshTried = false
        var meshWhy: String?
        var mediaWaiting = false
        var waiting = false
        var prompts = 0

        for item in queue {
            if !userInitiated, let notBefore = item.notBefore, notBefore > now { waiting = true; continue }
            let needsSigner = item.kind != .event
            if needsSigner && signerNeedsPerson {
                // Never from the background; at most a few prompts per tap.
                guard userInitiated || active, prompts < HomeVaultLogic.maxPromptsPerTap else { waiting = true; continue }
                if !userInitiated { waiting = true; continue }
                prompts += 1
            }

            // Everything signs as the owner it was queued for: with another
            // account active, an upload would carry that account's key.
            guard item.ownerHex == NostrService.shared.activeHexPubkey else { waiting = true; continue }

            let result: HomeVaultSendResult
            if item.kind == .mirror {
                let blossom = BlossomService(configService: ConfigService.shared, nostrService: NostrService.shared)
                let ok = await blossom.mirrorFromLocal(sha256: item.id, contentType: item.contentType ?? "application/octet-stream", server: item.server)
                result = ok ? .sent : .unreachable("no public server took it yet")
            } else {
                guard let vault = homeVault, vault.ownerHex == item.ownerHex,
                      vault.ownerHex == NostrService.shared.activeHexPubkey else { waiting = true; continue }
                if item.kind == .event && mediaWaiting { waiting = true; continue }
                if !meshTried {
                    meshTried = true
                    if let url = await FipsMeshService.shared.ingressURL(meshNpub: vault.meshNpub) {
                        base = url
                    } else {
                        meshWhy = "the mesh did not reach your home vault"
                    }
                }
                guard let base else {
                    if item.kind == .blob { mediaWaiting = true }
                    backOff(item)
                    waiting = true
                    continue
                }
                switch item.kind {
                case .event: result = await HomeVaultTransport.sendEvent(json: item.eventJSON ?? "", id: item.id, base: base)
                default: result = await sendBlob(item, base: base)
                }
            }
            switch result {
            case .sent:
                appLog("sent \(item.kind.rawValue) \(item.id.prefix(8))")
                remove(item)
            case .rejected(let why):
                // The other side read it and said no: retrying would only say no again.
                appLog("refused \(item.kind.rawValue) \(item.id.prefix(8)): \(why)", level: "WARN")
                remove(item)
            case .unreachable(let why):
                if item.kind == .blob { mediaWaiting = true }
                backOff(item)
                waiting = true
                appLog("\(item.kind.rawValue) \(item.id.prefix(8)) will retry: \(why)")
            }
        }

        if queue.isEmpty {
            lastResult = "Up to date"
            retryTimer?.invalidate()
            retryTimer = nil
        } else if waiting {
            noteFailure(meshWhy ?? "\(queue.count) waiting to retry")
        }
        // Giving up must not read like success on the card.
        if let first = gaveUp.first {
            lastResult = "Gave up: \(first)" + (gaveUp.count > 1 ? " (and \(gaveUp.count - 1) more)" : "") + ". It is still on this phone."
        }
    }

    private func backOff(_ item: HomeVaultItem) {
        guard let i = queue.firstIndex(where: { $0.kind == item.kind && $0.id == item.id }) else { return }
        queue[i].attempts += 1
        queue[i].notBefore = Date().addingTimeInterval(HomeVaultLogic.backoff(afterAttempts: queue[i].attempts))
        saveQueue()
    }

    private func sendBlob(_ item: HomeVaultItem, base: URL) async -> HomeVaultSendResult {
        // Streamed from a file: the bytes come from this phone's own Blossom,
        // where every post saves first, and never sit in memory whole.
        guard let file = await HomeVaultTransport.localBlobFile(sha256: item.id) else {
            return .rejected("not on this phone any more")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard let auth = await signUploadAuth(sha256: item.id, size: size) else {
            return .unreachable("could not sign the upload")
        }
        return await HomeVaultTransport.upload(file: file, size: size, sha256: item.id, contentType: item.contentType ?? "application/octet-stream", authBase64: auth, base: base)
    }

    /// Signed at send time: a queued item can wait longer than an auth lives.
    private func signUploadAuth(sha256: String, size: Int) async -> String? {
        let expiration = Int(Date().timeIntervalSince1970) + 600
        let tags = [["t", "upload"], ["x", sha256], ["size", String(size)], ["expiration", String(expiration)]]
        // A random word keeps two auths for the same blob in the same second
        // distinct: the vault takes each auth id once (#475), and its 403 for
        // a reuse would read here as a final no.
        let nonce = UUID().uuidString.prefix(8)
        guard let event = await NostrService.shared.signEventAsync(kind: 24242, content: "Upload to home vault \(nonce)", tags: tags) else { return nil }
        let dict: [String: Any] = ["id": event.id, "pubkey": event.pubkey, "created_at": event.created_at,
                                   "kind": event.kind, "tags": event.tags, "content": event.content, "sig": event.sig]
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return json.base64EncodedString()
    }

    /// The Logs screen and relay.log (stdout), as BlossomService does.
    private func appLog(_ message: String, level: String = "INFO") {
        RelayProcessManager.shared.addLog("Home vault: " + message, level: level)
        print("Home vault: \(message)")
    }

    private func noteFailure(_ why: String) {
        lastResult = "Waiting: \(why)"
        appLog("send paused, \(queue.count) waiting: \(why)")
        // Try again while the app is open; foregrounding also retries.
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard UIApplication.shared.applicationState == .active else { return }
                    self?.drainSoon()
                }
            }
        }
    }

    private func remove(_ item: HomeVaultItem) {
        queue.removeAll { $0.kind == item.kind && $0.id == item.id }
        saveQueue()
    }

    // MARK: - Persistence

    private static var queueURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("home_vault_queue.json")
    }

    private static func loadQueue() -> [HomeVaultItem] {
        guard let data = try? Data(contentsOf: queueURL) else { return [] }
        if let items = try? JSONDecoder().decode([HomeVaultItem].self, from: data) { return items }
        // Unreadable: set it aside rather than overwrite it with the next save.
        let aside = queueURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: queueURL, to: aside)
        print("Home vault: queue file unreadable, moved to \(aside.lastPathComponent)")
        return []
    }

    private func saveQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: Self.queueURL, options: [.atomic, Data.WritingOptions.completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The wire side, kept free of app state so it can be tested against a stub.
enum HomeVaultTransport {
    typealias SendResult = HomeVaultSendResult

    /// Publish one signed event over the vault's outbox websocket and wait for its OK.
    static func sendEvent(json: String, id: String, base: URL, timeout: TimeInterval = 20) async -> HomeVaultSendResult {
        guard let url = HomeVaultLogic.websocketURL(base: base) else { return .rejected("bad mesh URL") }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            try await socket.send(.string("[\"EVENT\",\(json)]"))
        } catch {
            return .unreachable("the home vault did not answer")
        }
        return await withTaskGroup(of: SendResult.self) { group in
            group.addTask {
                while true {
                    guard let message = try? await socket.receive() else {
                        return .unreachable("the home vault closed the connection")
                    }
                    guard case .string(let text) = message, let result = HomeVaultLogic.okResult(text, id: id) else { continue }
                    return result
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .unreachable("the home vault did not confirm in time")
            }
            let first = await group.next() ?? .unreachable("no answer")
            group.cancelAll()
            return first
        }
    }

    /// BUD-02 `PUT /upload` to the vault, streamed from `file`, with the owner's 24242 authorisation.
    static func upload(file: URL, size: Int, sha256: String, contentType: String, authBase64: String, base: URL) async -> SendResult {
        var request = URLRequest(url: base.appendingPathComponent("upload"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "X-SHA-256")
        // The door answers 411 (final) without a length; never leave it to URLSession.
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.upload(for: request, fromFile: file)
            return HomeVaultLogic.uploadResult(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .unreachable("the home vault did not take the upload")
        }
    }

    /// Whether the vault already serves `sha256` (its mesh door answers HEAD /<sha256>).
    static func vaultHas(sha256: String, base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent(sha256))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// A blob from this phone's own Blossom, downloaded to a temporary file
    /// the caller removes. Never loaded into memory whole.
    static func localBlobFile(sha256: String) async -> URL? {
        // As BlossomService.localBlossomURL: the relay's own port serves blobs.
        let port = await MainActor.run { ConfigService.shared.config.relayPort }
        guard let url = URL(string: "https://localhost:\(port)/\(sha256)") else { return nil }
        let session = URLSession(configuration: .ephemeral, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (temp, response) = try? await session.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // The download's file is removed when this returns: move it somewhere ours.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("homevault-\(sha256)-\(UUID().uuidString.prefix(6))")
        do { try FileManager.default.moveItem(at: temp, to: kept) } catch { return nil }
        return kept
    }
}
#endif

#if os(iOS)
import Foundation
import UIKit

/// Sends this phone's own notes and media to a home vault: another of the
/// owner's phones in kiosk mode, reached over the FIPS mesh. The kiosk keeps
/// them and passes notes on to the regular relays.
///
/// The home vault is one of the owner's own `fipsmesh://<npub>/` entries in
/// their kind 10063. The kiosk's mesh door takes `PUT /upload` and an outbox
/// websocket at `/`, and only for the owner's signature, so nothing is sent
/// for any other account.
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
    /// The kiosk caps uploads; anything larger is not queued.
    static let maxBlobBytes = 100 * 1024 * 1024

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
        add(HomeVaultItem(kind: .event, id: id, ownerHex: pubkey, eventJSON: json, contentType: nil, added: Date(), attempts: 0, notBefore: nil))
    }

    /// A blob just saved to this phone's own Blossom, signed for by `signer`.
    /// True when it is queued for the home vault.
    @discardableResult
    func enqueue(blobSha256 sha256: String, contentType: String, signer: String, byteCount: Int) -> Bool {
        guard let vault = homeVault, signer == vault.ownerHex else { return false }
        guard byteCount <= Self.maxBlobBytes else {
            appLog("\(sha256.prefix(8)) is \(byteCount) bytes, over the \(Self.maxBlobBytes) the kiosk takes — kept on this phone only", level: "WARN")
            return false
        }
        add(HomeVaultItem(kind: .blob, id: sha256, ownerHex: signer, eventJSON: nil, contentType: contentType, added: Date(), attempts: 0, notBefore: nil))
        return true
    }

    /// The public upload of a blob a note already links (kiosk-only case).
    /// Retried until the linked server has it, home vault or not.
    func enqueue(mirrorSha256 sha256: String, contentType: String, signer: String) {
        add(HomeVaultItem(kind: .mirror, id: sha256, ownerHex: signer, eventJSON: nil, contentType: contentType, added: Date(), attempts: 0, notBefore: Date().addingTimeInterval(60)))
    }

    private func add(_ item: HomeVaultItem) {
        guard !queue.contains(where: { $0.kind == item.kind && $0.id == item.id }) else { return }
        // Media before the notes that point at it, so a note never lands first.
        if let index = HomeVaultLogic.insertionIndex(for: item.kind, in: queue) {
            queue.insert(item, at: index)
        } else {
            queue.append(item)
        }
        // Over the cap the oldest mesh copy goes; a pending public upload is
        // kept, because a published note already links to where it will be.
        if queue.count > Self.maxQueue, let oldest = queue.firstIndex(where: { $0.kind != .mirror }) {
            let dropped = queue.remove(at: oldest)
            appLog("queue full — dropped the oldest (\(dropped.kind.rawValue) \(dropped.id.prefix(8)))", level: "WARN")
        }
        saveQueue()
        drainSoon()
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
        guard !sending, !queue.isEmpty else { return }
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
                let ok = await blossom.mirrorFromLocal(sha256: item.id, contentType: item.contentType ?? "application/octet-stream")
                result = ok ? .sent : .unreachable("no public server took it yet")
            } else {
                guard let vault = homeVault, vault.ownerHex == item.ownerHex,
                      vault.ownerHex == NostrService.shared.activeHexPubkey else { waiting = true; continue }
                if item.kind == .event && mediaWaiting { waiting = true; continue }
                if !meshTried {
                    meshTried = true
                    // The vault must still be in the owner's list: a kiosk that withdrew it is off.
                    let listed = HomeVaultLogic.meshEntries(serverList: NostrService.shared.serverLists[vault.ownerHex] ?? [], excluding: nil)
                    if !listed.contains(vault.meshNpub) {
                        meshWhy = "your home vault is not in your server list right now"
                    } else if let url = await FipsMeshService.shared.ingressURL(meshNpub: vault.meshNpub) {
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
        // The bytes come from this phone's own Blossom, where every post saves first.
        guard let data = await HomeVaultTransport.localBlob(sha256: item.id) else {
            return .rejected("not on this phone any more")
        }
        guard let auth = await signUploadAuth(sha256: item.id, size: data.count) else {
            return .unreachable("could not sign the upload")
        }
        return await HomeVaultTransport.upload(data: data, sha256: item.id, contentType: item.contentType ?? "application/octet-stream", authBase64: auth, base: base)
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

    /// BUD-02 `PUT /upload` to the vault, with the owner's 24242 authorisation.
    static func upload(data: Data, sha256: String, contentType: String, authBase64: String, base: URL) async -> HomeVaultSendResult {
        var request = URLRequest(url: base.appendingPathComponent("upload"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "X-SHA-256")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).upload(for: request, from: data)
            return HomeVaultLogic.uploadResult(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .unreachable("the home vault did not take the upload")
        }
    }

    /// A blob from this phone's own Blossom.
    static func localBlob(sha256: String) async -> Data? {
        // As BlossomService.localBlossomURL: the relay's own port serves blobs.
        let port = await MainActor.run { ConfigService.shared.config.relayPort }
        guard let url = URL(string: "https://localhost:\(port)/\(sha256)") else { return nil }
        let session = URLSession(configuration: .ephemeral, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
#endif

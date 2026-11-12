import Foundation

/// Sync pick 1 (Logen, 2026-11-12): the vault sends your phone's posts.
/// Exactly one device blasts each note: the vault if it confirms within
/// `VaultHandoffDecision.hold`, otherwise the phone.
///
/// The phone opens a websocket to its vault's mesh address with a kind 24242
/// `publish` token signed by this device's mesh key (never the account key),
/// waits for the vault's `["NOTICE", "publish-for-me: on"]`, then sends
/// `["EVENT", note]` and waits for its OK (haven-go mesh_publish.go). A
/// refused dial or upgrade, or any other first frame, falls back at once.
enum VaultPublishHandoff {
    /// The one gate for handing posts to the vault: true when a mesh vault
    /// is configured and dialed. A "Send through my vault" setting belongs
    /// here, and only here.
    static func isEnabled(config: HavenConfig) -> Bool {
        meshVault(config: config) != nil
    }

    /// The vault postEvent hands notes to, or nil to post as before.
    static func vault(config: HavenConfig) -> RelayConfiguration.MacMeshRelay? {
        isEnabled(config: config) ? meshVault(config: config) : nil
    }

    /// The Mac relay given as a mesh npub, dialed for that same npub this
    /// session (as RelayConfiguration.blastrRelays). Only the iPhone/iPad
    /// dials one; a Mac build has none.
    private static func meshVault(config: HavenConfig) -> RelayConfiguration.MacMeshRelay? {
        #if os(iOS)
        guard let npub = config.macRelayMeshNpub, let mesh = RelayConfiguration.macMeshRelay,
              mesh.npub == npub else { return nil }
        return mesh
        #else
        return nil
        #endif
    }

    /// Hands `message` (the `["EVENT", note]` frame) to `vault` and reports
    /// who sends the note, once, on the main thread. Never logs the vault's
    /// address: its path is the engine's token.
    static func handOff(eventId: String, message: String, to vault: RelayConfiguration.MacMeshRelay,
                        completion: @escaping (VaultHandoffDecision) -> Void) {
        // The vault takes each token id once: a random word keeps them apart.
        guard let url = URL(string: vault.url),
              let tags = MeshKeyAuth.publishTags(receiver: vault.npub),
              let auth = MeshKeySigner.authorization(kind: 24242, content: "Publish \(UUID().uuidString.prefix(8))", tags: tags)
        else {
            DispatchQueue.main.async { completion(.phoneSends) }
            return
        }
        Attempt(eventId: eventId, completion: completion).start(url: url, auth: auth, message: message)
    }

    /// One hand-off: one socket, one answer. Kept alive by its own callbacks
    /// and the hold timer. The note is sent only after the vault's first
    /// frame says it will send it (`VaultHandoffDecision.publishNotice`).
    private final class Attempt {
        private let eventId: String
        private let completion: (VaultHandoffDecision) -> Void
        private let lock = NSLock()
        private var finished = false
        private var sawPublishNotice = false
        private var session: URLSession?
        private var task: URLSessionWebSocketTask?

        init(eventId: String, completion: @escaping (VaultHandoffDecision) -> Void) {
            self.eventId = eventId
            self.completion = completion
        }

        func start(url: URL, auth: String, message: String) {
            var request = URLRequest(url: url, timeoutInterval: VaultHandoffDecision.hold)
            request.setValue("Haven/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("Nostr \(auth)", forHTTPHeaderField: "Authorization")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = VaultHandoffDecision.hold
            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: request)
            lock.lock()
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
            // A refused dial or a 401/403/409 upgrade fails this receive at
            // once, and the phone sends.
            receiveFirst(task, message: message)
            DispatchQueue.main.asyncAfter(deadline: .now() + VaultHandoffDecision.hold) { [self] in
                lock.lock(); let saw = sawPublishNotice; lock.unlock()
                finish(VaultHandoffDecision.decide(sawPublishNotice: saw, connected: saw, accepted: nil,
                                                   message: nil, timedOut: true))
            }
        }

        /// The vault's first frame: the publish notice, or the phone sends
        /// now (an older vault, or one that did not take the token).
        private func receiveFirst(_ task: URLSessionWebSocketTask, message: String) {
            task.receive { [self] result in
                guard case .success(let frame) = result, let text = Self.text(frame),
                      VaultHandoffDecision.isPublishNotice(frame: text) else {
                    finish(.phoneSends)
                    return
                }
                lock.lock(); sawPublishNotice = true; lock.unlock()
                task.send(.string(message)) { [self] error in
                    if error != nil { finish(.phoneSends) }
                }
                receiveOK(task)
            }
        }

        private func receiveOK(_ task: URLSessionWebSocketTask) {
            task.receive { [self] result in
                guard case .success(let frame) = result else {
                    finish(.phoneSends)
                    return
                }
                if let text = Self.text(frame), let ok = VaultHandoffDecision.okAnswer(frame: text, eventId: eventId) {
                    finish(VaultHandoffDecision.decide(sawPublishNotice: true, connected: true, accepted: ok.accepted,
                                                       message: ok.message, timedOut: false))
                } else {
                    receiveOK(task) // another NOTICE, another note's OK: keep listening
                }
            }
        }

        private static func text(_ frame: URLSessionWebSocketTask.Message) -> String? {
            switch frame {
            case .string(let s): return s
            case .data(let d): return String(data: d, encoding: .utf8)
            @unknown default: return nil
            }
        }

        private func finish(_ decision: VaultHandoffDecision) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let task = self.task, session = self.session
            self.task = nil
            self.session = nil
            lock.unlock()
            task?.cancel(with: .normalClosure, reason: nil)
            session?.invalidateAndCancel()
            #if DEBUG
            print("VaultPublishHandoff: \(eventId.prefix(8)) → \(decision)")
            #endif
            DispatchQueue.main.async { [completion] in completion(decision) }
        }
    }
}

extension NostrService {
    /// The vault took the note and sends it: the phone's own relay keeps a
    /// copy through `?pulled=1`, so it is stored here and never blasted
    /// (PulledInjection). Nothing is written while the relay is not up; the
    /// vault has the note.
    func keepHandedOffNote(_ eventDict: [String: Any]) {
        let relayReady = RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting
        guard relayReady, let url = PulledInjection.url(ConfigService.shared.config.nostrURL) else { return }
        broadcastRawEvent(eventDict, to: [url.absoluteString])
    }
}

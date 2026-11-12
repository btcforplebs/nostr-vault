import Foundation

/// One websocket to a vault's `/files` (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md
/// §1), used one step at a time: AUTH, then a query, a publish, or a live
/// subscription. Every frame lands in one stream, and each step reads it until
/// its own answer. Everything it signs is signed with this device's mesh key
/// (`MeshKeySigner.fileNotes`), never the account key. The Swift twin of
/// Android's `FilesSocket` (FileNotesLive.kt).
final class FilesSocket: @unchecked Sendable {
    static let stepTimeout: TimeInterval = 15

    private let url: URL
    private let vaultNpub: String?
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let frames: AsyncStream<[Any]>
    private let continuation: AsyncStream<[Any]>.Continuation
    private var iterator: AsyncStream<[Any]>.Iterator
    private var challenge: String?
    private var pinger: Task<Void, Never>?

    /// `vaultNpub`: the vault's mesh npub when reached over the mesh (the
    /// AUTH names its mesh address), nil for this machine's own relay.
    init(url: URL, vaultNpub: String?) {
        self.url = url
        self.vaultNpub = vaultNpub
        (frames, continuation) = AsyncStream<[Any]>.makeStream()
        iterator = frames.makeAsyncIterator()
        // The Mac's own relay and the mesh ingress are both on loopback.
        session = URLSession(configuration: .ephemeral, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.resume()
        receiveLoop()
        // Open after EOSE and quiet for as long as nothing is uploaded: a
        // ping every 30 s tells a dead link from a quiet one.
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.task.sendPing { error in if error != nil { self.close() } }
            }
        }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message, let data = text.data(using: .utf8),
                   let frame = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    self.continuation.yield(frame)
                }
                self.receiveLoop()
            case .failure:
                self.continuation.finish()
            }
        }
    }

    func close() {
        pinger?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        continuation.finish()
    }

    // MARK: Steps

    /// NIP-42 with the mesh key, on the vault's challenge: true once the room says OK.
    func auth(timeout: TimeInterval = stepTimeout) async -> Bool {
        if challenge == nil {
            _ = await read(timeout: timeout) { _ in self.challenge != nil ? true : nil }
        }
        guard let challenge else { return false }
        let relay = FileNote.authRelayURL(vaultNpub: vaultNpub, connected: url)
        guard let signed = MeshKeySigner.fileNotes(kind: FileNote.authKind, tags: FileNote.authTags(relayURL: relay, challenge: challenge)),
              let json = Self.json(signed), await send("[\"AUTH\",\(json)]") else { return false }
        return await ok(id: signed.id, timeout: timeout)?.accepted == true
    }

    /// `EVENT` and its `OK`, or nil with no answer.
    func publish(_ event: NostrEvent, timeout: TimeInterval = stepTimeout) async -> (accepted: Bool, message: String)? {
        guard let json = Self.json(event), await send("[\"EVENT\",\(json)]") else { return nil }
        return await ok(id: event.id, timeout: timeout)
    }

    /// Every event up to EOSE for `filter`, or nil when the room closed it or did not answer.
    func query(subId: String, filter: [String: Any], timeout: TimeInterval = stepTimeout) async -> [[String: Any]]? {
        guard let frame = Self.text(["REQ", subId, filter]), await send(frame) else { return nil }
        var found: [[String: Any]] = []
        let done = await read(timeout: timeout) { frame -> Bool? in
            guard frame.count >= 2, frame[1] as? String == subId else { return nil }
            switch frame[0] as? String {
            case "EVENT": if let ev = frame[safe: 2] as? [String: Any] { found.append(ev) }; return nil
            case "EOSE": return true
            case "CLOSED": return false
            default: return nil
            }
        }
        _ = await send("[\"CLOSE\",\"\(subId)\"]")
        return done == true ? found : nil
    }

    /// A live REQ: each event to `onEvent`, until the room closes it or the socket drops.
    func subscribe(subId: String, filter: [String: Any], onEvent: @escaping ([String: Any]) async -> Void) async {
        guard let frame = Self.text(["REQ", subId, filter]), await send(frame) else { return }
        while let frame = await next() {
            guard frame.count >= 2, frame[1] as? String == subId else { continue }
            switch frame[0] as? String {
            case "EVENT": if let ev = frame[safe: 2] as? [String: Any] { await onEvent(ev) }
            case "CLOSED": return
            default: continue
            }
        }
    }

    // MARK: Plumbing

    private func ok(id: String, timeout: TimeInterval) async -> (accepted: Bool, message: String)? {
        await read(timeout: timeout) { frame in
            guard frame.count >= 3, frame[0] as? String == "OK", frame[1] as? String == id else { return nil }
            return ((frame[2] as? Bool) ?? false, (frame[safe: 3] as? String) ?? "")
        }
    }

    /// Frames until `answer` gives one, or nil at `timeout` (the socket is
    /// then closed: a step that timed out leaves it unusable anyway).
    private func read<T>(timeout: TimeInterval, _ answer: ([Any]) -> T?) async -> T? {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { self?.close() }
        }
        defer { timer.cancel() }
        while let frame = await next() {
            if let value = answer(frame) { return value }
        }
        return nil
    }

    /// The next frame; an AUTH challenge is kept for `auth`.
    private func next() async -> [Any]? {
        while let frame = await iterator.next() {
            // The caller may be waiting on the challenge itself, so it is
            // passed on too.
            if frame.first as? String == "AUTH", let c = frame[safe: 1] as? String { challenge = c }
            return frame
        }
        return nil
    }

    private func send(_ text: String) async -> Bool {
        do { try await task.send(.string(text)); return true } catch { return false }
    }

    static func json(_ event: NostrEvent) -> String? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func text(_ frame: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

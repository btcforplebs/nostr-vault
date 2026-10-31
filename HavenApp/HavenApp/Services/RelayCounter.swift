import Combine
import Foundation

/// Sends NIP-45 COUNTs to one of the vault's own relays over one socket,
/// AUTHing as the owner first on the routes that need it. `RelayCountSession`
/// decides what each relay message means; this does the socket and signing.
///
/// Nil means "couldn't count": the socket failed, the relay refused, or not
/// every COUNT was answered in time. Never read nil as 0.
@MainActor
final class RelayCounter {
    /// Asks `url` every filter, keyed as given, and returns the counts under
    /// the same keys.
    static func count(_ filters: [String: [String: Any]], at url: URL, timeout: TimeInterval = 25) async -> [String: Int]? {
        guard !filters.isEmpty else { return [:] }
        let needsAuth = RelayCountSession.needsAuth(url)
        // Watch-only: nothing to sign the AUTH with, so this route can't be counted.
        if needsAuth && !ownerCanAuth() { return nil }
        guard needsAuth else {
            return await RelayCounter(filters: filters, url: url, needsAuth: false).run(timeout: timeout)
        }

        // A kept socket is still logged in: count with no new AUTH.
        let owner = ConfigService.shared.config.ownerNpub
        if let socket = kept.socket(owner: owner, url: url) {
            let counter = RelayCounter(filters: filters, url: url, needsAuth: false, client: socket)
            if let counts = await counter.run(timeout: timeout) { return counts }
            // Dead or refused: close it and log in again on a new one.
            kept.drop(socket, owner: owner, url: url)
            socket.disconnect()
        }

        let counter = RelayCounter(filters: filters, url: url, needsAuth: true)
        let counts = await counter.run(timeout: timeout)
        if counts != nil {
            counter.keepOpen(owner: owner)
        } else {
            counter.client.disconnect()
        }
        return counts
    }

    /// Logged-in /private and /chat sockets, reused by the next count.
    private static var kept = KeptCountSockets<WebSocketClient>()
    private static var keptWatches: [ObjectIdentifier: AnyCancellable] = [:]

    /// Whether the owner can sign the AUTH /private and /chat need, whichever
    /// account is active (`HavenConfig.ownerCanSign`, the rule DM's /chat AUTH
    /// uses too).
    static func ownerCanAuth() -> Bool {
        ConfigService.shared.config.ownerCanSign(
            hasNcryptsecPassword: NIP49Service.getPasswordFromKeychain() != nil
        )
    }

    private let filters: [String: [String: Any]]
    private let url: URL
    private let client: WebSocketClient
    /// Counting on a kept socket that is already open and logged in.
    private let reused: Bool
    private var session: RelayCountSession
    private var watches = Set<AnyCancellable>()
    private var continuation: CheckedContinuation<[String: Int]?, Never>?

    private init(filters: [String: [String: Any]], url: URL, needsAuth: Bool, client: WebSocketClient? = nil) {
        self.filters = filters
        self.url = url
        self.reused = client != nil
        self.client = client ?? WebSocketClient()
        session = RelayCountSession(
            keys: Set(filters.keys),
            prefix: "vc-\(UUID().uuidString.prefix(6))-",
            needsAuth: needsAuth)
        self.client.isTemporary = true
    }

    /// Keeps this logged-in socket for the next count, until it drops.
    private func keepOpen(owner: String) {
        let socket = client
        Self.kept.keep(socket, owner: owner, url: url)?.disconnect()
        let id = ObjectIdentifier(socket)
        Self.keptWatches[id] = socket.$connectionState
            .dropFirst()
            .filter { $0 != .connected }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Self.kept.forget(socket)
                Self.keptWatches[id] = nil
                socket.disconnect()
            }
    }

    private func run(timeout: TimeInterval) async -> [String: Int]? {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<[String: Int]?, Never>) in
            continuation = cont
            // Listen before connecting: /private and /chat send their AUTH
            // challenge the moment the socket opens.
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] text in
                    guard let self else { return }
                    self.apply(self.session.receive(text))
                }
                .store(in: &watches)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self else { return }
                    if state == .connected { self.apply(self.session.connected()) }
                    if state == .error || (self.reused && state == .disconnected) { self.end(nil) }
                }
                .store(in: &watches)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.end(nil)
            }
            // A kept socket is open already: its state publishes .connected
            // to the watch above at once, which sends the counts.
            if !reused { client.connect(url: url) }
        }
        // `count` decides whether a logged-in socket stays open.
        if !session.needsAuth && !reused { client.disconnect() }
        return result
    }

    private func apply(_ step: RelayCountSession.Step) {
        switch step {
        case .wait:
            break
        case .signAuth(let challenge):
            Task { await authenticate(challenge: challenge) }
        case .sendCounts:
            for (key, filter) in filters {
                send(["COUNT", session.prefix + key, filter])
            }
        case .finished(let counts):
            end(counts)
        case .failed:
            end(nil)
        }
    }

    private func authenticate(challenge: String) async {
        // The relay tag must be the relay's ServiceURL, not the 127.0.0.1
        // address dialed: with a domain or tunnel set, that is the domain.
        let relay = ConfigService.shared.config.nostrURL + "/" + url.lastPathComponent
        guard let event = await NostrService.shared.signEventAsync(
            kind: 22242, content: "",
            tags: [["relay", relay], ["challenge", challenge]],
            forceOwner: true
        ) else {
            // A bunker owner with no session yet (restart with another account
            // active): log it in, so the next count can AUTH.
            NIP46Service.shared.connectOwnerInBackgroundIfNeeded()
            apply(session.authUnavailable())
            return
        }
        session.authSent(id: event.id)
        send(["AUTH", [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig,
        ] as [String: Any]])
    }

    private func send(_ message: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        client.send(text: text)
    }

    private func end(_ result: [String: Int]?) {
        guard let cont = continuation else { return }
        continuation = nil
        watches.removeAll()
        cont.resume(returning: result)
    }
}

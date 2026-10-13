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
        return await RelayCounter(filters: filters, url: url, needsAuth: needsAuth).run(timeout: timeout)
    }

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
    private let client = WebSocketClient()
    private var session: RelayCountSession
    private var watches = Set<AnyCancellable>()
    private var continuation: CheckedContinuation<[String: Int]?, Never>?

    private init(filters: [String: [String: Any]], url: URL, needsAuth: Bool) {
        self.filters = filters
        self.url = url
        session = RelayCountSession(
            keys: Set(filters.keys),
            prefix: "vc-\(UUID().uuidString.prefix(6))-",
            needsAuth: needsAuth)
        client.isTemporary = true
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
                    if state == .error { self.end(nil) }
                }
                .store(in: &watches)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.end(nil)
            }
            client.connect(url: url)
        }
        client.disconnect()
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

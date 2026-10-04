import Foundation
import Combine

/// Whether an event's id and signature check out (`NostrEventVerifier`).
enum SignatureCheck: Equatable {
    case valid
    case invalid
    /// No full signed event yet: still fetching, or no relay had it.
    case unknown
}

/// What one relay said when asked for the event by id.
enum RelayPresence: Equatable {
    case checking
    case found
    case notFound
    case failed(String)
}

/// The data behind the Event Info sheet: finds the full signed event, checks
/// its signature, asks each relay whether it has the event ("seen on"), and
/// re-broadcasts to the relays the person picks.
@MainActor
final class EventInspector: ObservableObject {
    let note: FeedNote

    /// The full signed event (with sig) once found.
    @Published private(set) var event: [String: Any]?
    @Published private(set) var isFetching = false
    @Published private(set) var signature: SignatureCheck = .unknown
    /// Relays asked, in display order: this device's relay (outbox, then
    /// inbox), your feed relays, your blastr relays. No duplicates.
    @Published private(set) var relays: [String] = []
    @Published private(set) var presence: [String: RelayPresence] = [:]

    /// How long one relay gets to answer before it counts as failed.
    static let relayTimeout: TimeInterval = 6
    private static let fallbackRelays = ["wss://relay.primal.net", "wss://nos.lol"]

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(note: FeedNote) {
        self.note = note
    }

    deinit {
        clients.forEach { $0.disconnect() }
    }

    /// Where Re-Broadcast sends by default: the blastr relays, as before.
    var defaultBroadcastRelays: [String] {
        let blastr = ConfigService.shared.config.activeBlastrRelays
        return blastr.isEmpty ? Self.fallbackRelays : blastr
    }

    /// "This device" for the local relay's paths, the bare host for the rest.
    static func label(for relay: String) -> String {
        let base = ConfigService.shared.config.nostrURL
        if relay == base { return "This device" }
        if relay == base + "/inbox" { return "This device (inbox)" }
        return relay
            .replacingOccurrences(of: "wss://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Starts the lookup. Safe to call again (e.g. on re-appear); it runs once.
    func start() {
        guard !started else { return }
        started = true

        if let cached = FeedService.shared.rawEventCache[note.id],
           let data = cached.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            adopt(dict)
        }

        let config = ConfigService.shared.config
        let base = config.nostrURL
        let feed = config.activeFeedRelays.isEmpty ? Self.fallbackRelays : config.activeFeedRelays
        var ordered: [String] = []
        for relay in [base, base + "/inbox"] + feed + defaultBroadcastRelays
        where !relay.isEmpty && !ordered.contains(relay) {
            ordered.append(relay)
        }
        relays = ordered
        presence = Dictionary(uniqueKeysWithValues: ordered.map { ($0, .checking) })
        isFetching = event == nil
        ordered.forEach(ask)
    }

    /// Sends the full signed event to `relays`. `onResult` gets each relay's
    /// answer: (relay, accepted, the relay's own message, "timeout" or
    /// "connection failed"). A relay that accepts it now counts as seen on.
    func broadcast(to relays: [String], onResult: @escaping (String, Bool, String) -> Void) {
        guard let event else { return }
        NostrService.shared.broadcastRawEvent(event, to: relays) { [weak self] relay, ok, message in
            if ok, let self {
                if !self.relays.contains(relay) { self.relays.append(relay) }
                self.presence[relay] = .found
            }
            onResult(relay, ok, message)
        }
    }

    // MARK: - Private

    private func ask(_ relay: String) {
        guard let url = URL(string: relay) else {
            presence[relay] = .failed("bad relay address")
            return
        }
        let subId = "inspect-\(UUID().uuidString.prefix(8))"
        let req: [Any] = ["REQ", subId, ["ids": [note.id], "limit": 1]]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let reqText = String(data: data, encoding: .utf8) else { return }

        let client = WebSocketClient()
        client.isTemporary = true
        clients.append(client)

        client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] message in
                guard let self, self.presence[relay] == .checking,
                      let msgData = message.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: msgData) as? [Any],
                      json.count >= 2, let type = json[0] as? String,
                      json[1] as? String == subId else { return }
                switch type {
                case "EVENT":
                    guard json.count >= 3, let ev = json[2] as? [String: Any],
                          ev["id"] as? String == self.note.id else { return }
                    // A relay can send anything under any id; only a copy that
                    // verifies counts as having the event.
                    if NostrEventVerifier.isValid(ev) {
                        self.presence[relay] = .found
                        if self.event == nil || self.signature != .valid { self.adopt(ev) }
                    } else {
                        self.presence[relay] = .failed("sent a copy that fails the signature check")
                    }
                    self.finish(relay, client)
                case "EOSE":
                    self.presence[relay] = .notFound
                    self.finish(relay, client)
                case "CLOSED":
                    let reason = json.count >= 3 ? (json[2] as? String ?? "") : ""
                    self.presence[relay] = .failed(reason.isEmpty ? "refused the request" : reason)
                    self.finish(relay, client)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self, self.presence[relay] == .checking else { return }
                if state == .connected {
                    client?.send(text: reqText)
                } else if state == .error {
                    self.presence[relay] = .failed("connection failed")
                    self.finish(relay, client)
                }
            }
            .store(in: &cancellables)

        client.connect(url: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.relayTimeout) { [weak self, weak client] in
            guard let self, self.presence[relay] == .checking else { return }
            self.presence[relay] = .failed("timeout")
            self.finish(relay, client)
        }
    }

    private func finish(_ relay: String, _ client: WebSocketClient?) {
        client?.disconnect()
        if !presence.values.contains(.checking) { isFetching = false }
    }

    private func adopt(_ dict: [String: Any]) {
        event = dict
        if dict["sig"] as? String == nil {
            signature = .unknown
        } else {
            signature = NostrEventVerifier.isValid(dict) ? .valid : .invalid
        }
        isFetching = false
    }
}

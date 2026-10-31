#if os(iOS)
import Foundation
import Combine

/// Hands this phone's own signed notes to a browser relay: a
/// `nostrvault.app` page that keeps no key and runs a relay over the FIPS mesh.
/// The page checks each signature and keeps only its owner's notes.
///
/// The page is set up here by its mesh address (shown on the page). New notes
/// go to it as they are published, and "Send my latest notes" sends the
/// recent ones from this phone's relay. Nothing is signed here: libnvfips
/// sends each event exactly as it was published. While the app is open only;
/// a note that cannot reach the page is not queued (send the latest again).
@MainActor
final class BrowserRelaySender: ObservableObject {
    static let shared = BrowserRelaySender()

    struct BrowserRelay: Codable, Equatable {
        /// The account whose notes go to the page.
        let ownerHex: String
        /// The page's mesh address.
        let meshNpub: String
    }

    @Published private(set) var relay: BrowserRelay?
    @Published private(set) var sending = false
    @Published private(set) var lastResult: String?

    private static let relayKey = "browserRelay.v1"
    /// How many of your notes "Send my latest notes" takes from this phone's relay.
    static let latestCount = 20

    /// Events waiting for the push in flight to finish.
    private var pending: [[String: Any]] = []

    /// Read off the main thread by the engine's start options.
    nonisolated static var isOn: Bool {
        UserDefaults.standard.data(forKey: relayKey) != nil
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.relayKey) {
            relay = try? JSONDecoder().decode(BrowserRelay.self, from: data)
        }
    }

    func setRelay(_ new: BrowserRelay?) {
        relay = new
        if let new, let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: Self.relayKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.relayKey)
        }
        pending.removeAll()
        lastResult = nil
    }

    /// A signed event this phone just published. Only the relay owner's own notes.
    func enqueue(eventDict: [String: Any]) {
        guard let relay, eventDict["pubkey"] as? String == relay.ownerHex,
              eventDict["kind"] as? Int == 1 else { return }
        pending.append(eventDict)
        Task { await drain() }
    }

    /// The latest notes of the relay's owner from this phone's own relay.
    func sendLatest() async {
        guard let relay else { return }
        lastResult = "Reading your notes on this phone…"
        let notes = await Self.localNotes(author: relay.ownerHex, limit: Self.latestCount)
        guard !notes.isEmpty else {
            lastResult = "No notes of yours on this phone yet"
            return
        }
        pending.append(contentsOf: notes)
        await drain()
    }

    private func drain() async {
        guard !sending, let relay else { return }
        sending = true
        defer { sending = false }
        while !pending.isEmpty, self.relay == relay {
            let batch = Array(pending.prefix(Self.latestCount))
            pending.removeFirst(batch.count)
            guard let data = try? JSONSerialization.data(withJSONObject: batch),
                  let json = String(data: data, encoding: .utf8) else { continue }
            lastResult = "Sending \(batch.count) to the browser vault…"
            let result = await FipsMeshService.shared.relayPush(relayNpub: relay.meshNpub, eventsJSON: json)
            lastResult = Self.describe(result, count: batch.count)
            print("BrowserRelay: \(lastResult ?? "")")
        }
    }

    struct PushResult: Decodable {
        struct Ack: Decodable {
            let id: String
            let accepted: Bool
            let message: String
        }
        let ok: Bool
        let acks: [Ack]?
        let not_accepted: [String]?
        let error: String?
    }

    static func describe(_ result: Result<String, FipsMeshService.MeshError>, count: Int) -> String {
        switch result {
        case .failure(let error):
            return error.message
        case .success(let json):
            guard let parsed = try? JSONDecoder().decode(PushResult.self, from: Data(json.utf8)) else {
                return "The browser vault sent an answer this app can't read"
            }
            let accepted = parsed.acks?.filter(\.accepted).count ?? 0
            if parsed.ok { return "The browser vault kept \(accepted) of \(count)" }
            if parsed.acks?.isEmpty ?? true {
                return "The browser vault did not answer. Tap Start mesh on the page after this phone is connected, then send again."
            }
            let reason = parsed.acks?.first(where: { !$0.accepted })?.message ?? parsed.error ?? ""
            return "The browser vault kept \(accepted) of \(count)" + (reason.isEmpty ? "" : ": \(reason)")
        }
    }

    /// Notes by `author` from this phone's relay (the outbox route, where your
    /// own notes are), newest first. Empty if the relay does not answer.
    private static func localNotes(author: String, limit: Int) async -> [[String: Any]] {
        guard let url = URL(string: ConfigService.shared.config.nostrURL) else { return [] }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[[String: Any]], Never>) in
            var found: [[String: Any]] = []
            var resumed = false
            var subs = Set<AnyCancellable>()
            let client = WebSocketClient()
            client.isTemporary = true
            let subId = "browser-relay-\(UUID().uuidString.prefix(6))"

            // Everything below runs on the main queue, so no lock.
            func finish() {
                guard !resumed else { return }
                resumed = true
                client.disconnect()
                subs.removeAll()
                continuation.resume(returning: found)
            }

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard let data = message.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json.first as? String,
                          json[safe: 1] as? String == subId else { return }
                    if type == "EVENT", let dict = json[safe: 2] as? [String: Any],
                       dict["pubkey"] as? String == author {
                        found.append(dict)
                    } else if type == "EOSE" || type == "CLOSED" {
                        finish()
                    }
                }
                .store(in: &subs)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    switch state {
                    case .connected:
                        let req = ["REQ", subId, ["authors": [author], "kinds": [1], "limit": limit]] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let text = String(data: data, encoding: .utf8) {
                            client.send(text: text)
                        }
                    case .error:
                        finish()
                    default:
                        break
                    }
                }
                .store(in: &subs)
            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
        }
    }
}
#endif

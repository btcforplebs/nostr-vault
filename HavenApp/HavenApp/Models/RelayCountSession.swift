import Foundation

/// One socket's worth of NIP-45 COUNTs against one of the vault's own
/// relays, as a state machine over the messages the relay sends back.
/// `RelayCounter` does the socket and the signing; this decides what each
/// message means.
///
/// `/private` and `/chat` only count for the owner (haven-go/init.go
/// `RejectCountFilter`), so there the session waits for the AUTH challenge,
/// has it signed, and sends no COUNT until the relay accepts that AUTH: khatru
/// handles each message on its own goroutine, so a COUNT sent right behind
/// the AUTH can be checked before the login lands.
///
/// A refused COUNT still gets a `{"count":0}` reply after a NOTICE, and a
/// NOTICE names no subscription, so any NOTICE fails the whole session. A
/// failed session means "couldn't count", never 0.
struct RelayCountSession {
    enum Step: Equatable {
        /// Nothing to do yet.
        case wait
        /// Sign a NIP-42 AUTH for this challenge and call `authSent(id:)`.
        case signAuth(challenge: String)
        /// Send every COUNT now.
        case sendCounts
        /// Every COUNT answered, keyed like the filters.
        case finished([String: Int])
        /// Couldn't count on this relay.
        case failed
    }

    /// The routes that count only for the authenticated owner.
    static let authRoutes: Set<String> = ["private", "chat"]

    /// Whether a COUNT on `url` needs the owner's AUTH first.
    static func needsAuth(_ url: URL) -> Bool {
        authRoutes.contains(url.lastPathComponent)
    }

    let keys: Set<String>
    let prefix: String
    let needsAuth: Bool

    private var challengeTaken = false
    private var authEventId: String?
    private var countsSent = false
    private var results: [String: Int] = [:]
    private var over = false

    init(keys: Set<String>, prefix: String, needsAuth: Bool) {
        self.keys = keys
        self.prefix = prefix
        self.needsAuth = needsAuth
    }

    /// The socket opened. A route without AUTH counts right away.
    mutating func connected() -> Step {
        guard !over, !needsAuth, !countsSent else { return .wait }
        countsSent = true
        return .sendCounts
    }

    /// The AUTH event for the challenge went out with this id.
    mutating func authSent(id: String) {
        authEventId = id
    }

    /// The AUTH could not be signed (no owner key, signer refused).
    mutating func authUnavailable() -> Step {
        finish(.failed)
    }

    mutating func receive(_ text: String) -> Step {
        guard !over,
              let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = message.first as? String else { return .wait }

        switch type {
        case "AUTH":
            guard needsAuth, !challengeTaken, let challenge = message.dropFirst().first as? String else { return .wait }
            challengeTaken = true
            return .signAuth(challenge: challenge)

        case "OK":
            guard let id = message.dropFirst().first as? String, id == authEventId, !countsSent else { return .wait }
            guard message.count >= 3, message[2] as? Bool == true else { return finish(.failed) }
            countsSent = true
            return .sendCounts

        case "NOTICE":
            return finish(.failed)

        case "CLOSED":
            guard let subId = message.dropFirst().first as? String, subId.hasPrefix(prefix) else { return .wait }
            return finish(.failed)

        case "COUNT":
            guard message.count >= 3,
                  let subId = message[1] as? String, subId.hasPrefix(prefix) else { return .wait }
            let key = String(subId.dropFirst(prefix.count))
            guard keys.contains(key) else { return .wait }
            guard let payload = message[2] as? [String: Any],
                  let count = Self.count(payload["count"]) else { return finish(.failed) }
            results[key] = count
            return results.count == keys.count ? finish(.finished(results)) : .wait

        default:
            return .wait
        }
    }

    private mutating func finish(_ step: Step) -> Step {
        over = true
        return step
    }

    /// The number in a COUNT reply. Relays send it as an integer, a float
    /// or a string; anything else, or a negative, is no answer.
    private static func count(_ raw: Any?) -> Int? {
        let value: Int?
        switch raw {
        case let n as NSNumber: value = n.intValue
        case let s as String: value = Int(s)
        default: value = nil
        }
        guard let value, value >= 0 else { return nil }
        return value
    }
}

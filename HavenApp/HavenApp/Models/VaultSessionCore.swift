import Foundation

/// One connection to this device's vault relay at one path, shared by every
/// request to that path for as long as it stays open: it logs in (NIP-42
/// AUTH) once, then each request rides the logged-in socket.
///
/// It used to be a new socket and a new AUTH per request. With a remote
/// signer (NIP-46 bunker) every AUTH is a round trip to the person's signer:
/// Logen's iPhone sent 2,262 logins to its own vault in three days, ~34 for
/// each list change (LogePhone relay.log, 2026-11-05).
///
/// Pure (no sockets, no signing): VaultSocket feeds it what happens and does
/// what it returns. The NIP-42 order is VaultAuthGate's: send on connect,
/// answer the connection's challenge once, and resend a refused request only
/// after the vault's OK for that AUTH; one `auth-required` after the OK gets
/// one retry. Tested in MediaLogicTests.
struct VaultSessionCore {
    enum Kind: Equatable { case req, event }

    enum Outcome {
        /// A REQ's events (raw JSON objects), up to its EOSE.
        case events([Any])
        /// An EVENT's OK: accepted, or already held.
        case accepted(Bool)
        /// No answer: refused, dropped or timed out.
        case failed
    }

    enum Effect {
        case connect
        case disconnect
        case send(String)
        /// Sign a kind 22242 for this challenge, then call `authSigned`.
        case signAuth(challenge: String)
        case finish(key: String, Outcome)
    }

    enum Link: Equatable { case down, connecting, up }

    enum Auth: Equatable {
        case none
        case signing
        case sent(id: String)
        case authed
    }

    private struct Op {
        let kind: Kind
        let frame: String
        var sent = false
        /// `heard` when it was last sent.
        var sentAt = 0
        var retried = false
        var events: [Any] = []
        /// Which submission of `key` this is (`submit`'s token).
        let token: Int
    }

    private(set) var link: Link = .down
    private(set) var auth: Auth = .none
    private var ops: [String: Op] = [:]
    private var order: [String] = []
    /// Messages received on this socket, to tell a slow vault from a dead
    /// socket (one iOS killed while the app was away still reads connected).
    private var heard = 0
    /// Submissions so far: each one's token, so a timer set for an earlier
    /// submission of the same key can't end a later one.
    private var submissions = 0

    /// No request waiting: the socket may be closed when it stays so.
    var isIdle: Bool { ops.isEmpty }

    /// A request: `key` is a REQ's subscription id or an EVENT's id, `frame`
    /// the JSON text to send. `token` names this submission for `timedOut`.
    /// The same key asked again while the first is out (one event published
    /// twice): the first ends `.failed`, and the socket is not judged by it.
    mutating func submit(key: String, kind: Kind, frame: String) -> (token: Int, effects: [Effect]) {
        var out: [Effect] = []
        if ops[key] != nil { out.append(finish(key, .failed)) }
        submissions += 1
        ops[key] = Op(kind: kind, frame: frame, token: submissions)
        order.append(key)
        switch link {
        case .down:
            link = .connecting
            out.append(.connect)
        case .connecting:
            break
        case .up:
            out += sendReady()
        }
        return (submissions, out)
    }

    mutating func connected() -> [Effect] {
        link = .up
        auth = .none
        heard = 0
        return sendReady()
    }

    /// The socket closed or failed: whatever was asked on it gets no answer.
    /// The next request opens a new one (and logs in again).
    mutating func disconnected() -> [Effect] {
        guard link != .down else { return [] }
        link = .down
        auth = .none
        return failAll()
    }

    /// The AUTH for the challenge is signed: send it, and hold every request
    /// until the vault's OK for it.
    mutating func authSigned(id: String, frame: String) -> [Effect] {
        guard auth == .signing else { return [] }
        auth = .sent(id: id)
        return [.send(frame)]
    }

    /// No AUTH could be signed (a bunker with no session yet): nothing on
    /// this socket can be answered. Close it; the next request tries again.
    mutating func authUnavailable() -> [Effect] {
        guard auth == .signing else { return [] }
        link = .down
        auth = .none
        return [.disconnect] + failAll()
    }

    /// Gave up waiting for submission `token` of `key`. A timer for an
    /// earlier submission (already ended) does nothing.
    mutating func timedOut(key: String, token: Int) -> [Effect] {
        guard let op = ops[key], op.token == token else { return [] }
        // Nothing at all heard on the socket since this was sent: the socket
        // is dead, not the vault slow. Close it, so the next request opens a
        // new one instead of waiting out its own timeout on this one.
        if op.sent, link == .up, op.sentAt == heard {
            link = .down
            auth = .none
            return [.disconnect] + failAll()
        }
        var out: [Effect] = []
        if op.kind == .req, op.sent, link == .up { out.append(.send(Self.closeFrame(key))) }
        out.append(finish(key, .failed))
        return out
    }

    /// One message from the vault: `type` is the array's first element.
    mutating func received(type: String, _ arr: [Any]) -> [Effect] {
        heard += 1
        switch type {
        case "AUTH":
            // One login per connection: a later challenge on a logged-in
            // socket is not answered.
            guard auth == .none, let challenge = arr.count > 1 ? arr[1] as? String : nil else { return [] }
            auth = .signing
            return [.signAuth(challenge: challenge)]
        case "OK":
            guard arr.count > 1, let id = arr[1] as? String else { return [] }
            if case .sent(let authId) = auth, id == authId {
                guard (arr.count > 2 ? arr[2] as? Bool : nil) == true else {
                    // The vault refused our login: close; the next request
                    // starts over.
                    link = .down
                    auth = .none
                    return [.disconnect] + failAll()
                }
                auth = .authed
                return sendReady()
            }
            guard ops[id]?.kind == .event else { return [] }
            if VaultAuthGate.isAuthRequired(type: type, arr) { return authRequired(id) }
            let accepted = (arr.count > 2 ? arr[2] as? Bool : nil) ?? false
            let reason = (arr.count > 3 ? arr[3] as? String : nil) ?? ""
            return [finish(id, .accepted(accepted || reason.hasPrefix("duplicate")))]
        case "EVENT":
            guard arr.count > 2, let sub = arr[1] as? String, ops[sub]?.kind == .req else { return [] }
            ops[sub]?.events.append(arr[2])
            return []
        case "EOSE":
            guard arr.count > 1, let sub = arr[1] as? String, let op = ops[sub], op.kind == .req else { return [] }
            // The socket stays open: end the subscription on the vault too.
            return [.send(Self.closeFrame(sub)), finish(sub, .events(op.events))]
        case "CLOSED":
            guard arr.count > 1, let sub = arr[1] as? String, ops[sub]?.kind == .req else { return [] }
            if VaultAuthGate.isAuthRequired(type: type, arr) { return authRequired(sub) }
            return [finish(sub, .failed)]
        default:
            return []
        }
    }

    // MARK: - Private

    /// Refused for want of a login: before the AUTH's OK it goes again on
    /// that OK; after it, one retry.
    private mutating func authRequired(_ key: String) -> [Effect] {
        guard var op = ops[key] else { return [] }
        if auth != .authed {
            op.sent = false
            ops[key] = op
            return []
        }
        guard !op.retried else {
            // Logged in, and still refused for want of a login after its
            // retry: this socket's login is no good. Close it, so the next
            // request logs in afresh instead of every one failing on it.
            link = .down
            auth = .none
            return [.disconnect] + failAll()
        }
        op.retried = true
        op.sent = true
        op.sentAt = heard
        ops[key] = op
        return [.send(op.frame)]
    }

    /// Sends every request not yet sent, unless a login is under way (they
    /// go on its OK).
    private mutating func sendReady() -> [Effect] {
        guard link == .up else { return [] }
        switch auth {
        case .signing, .sent: return []
        case .none, .authed: break
        }
        var out: [Effect] = []
        for key in order {
            guard var op = ops[key], !op.sent else { continue }
            op.sent = true
            op.sentAt = heard
            ops[key] = op
            out.append(.send(op.frame))
        }
        return out
    }

    private mutating func finish(_ key: String, _ outcome: Outcome) -> Effect {
        ops[key] = nil
        order.removeAll { $0 == key }
        return .finish(key: key, outcome)
    }

    private mutating func failAll() -> [Effect] {
        let keys = order
        return keys.map { finish($0, .failed) }
    }

    static func closeFrame(_ sub: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["CLOSE", sub]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

/// Reading more than one answer's worth (a vault caps a REQ at `limit`):
/// newest first, each page asking `until` the oldest of the last. Every
/// version comes, whatever the kinds, in as few asks as it takes; it replaced
/// a re-ask per kind (16 of them) whenever the first answer hit the cap.
enum VaultPaging {
    static let limit = 1000
    /// A backstop: 50,000 versions.
    static let maxPages = 50

    /// The next page's `until`, or nil when `page` was the last: it came back
    /// under the limit (`known` holds every id read before it). A full page
    /// that brought nothing new is one second holding a page or more of
    /// versions: the next page asks from the second before it, so paging
    /// goes on past it (those of that second past the page are not read).
    static func nextUntil(page: [(id: String, createdAt: Int)], known: Set<String>, limit: Int = limit) -> Int? {
        guard page.count >= limit, let oldest = page.map(\.createdAt).min() else { return nil }
        return page.contains(where: { !known.contains($0.id) }) ? oldest : oldest - 1
    }
}

import Foundation

/// One kept, logged-in connection to a path of this device's vault ("" the
/// main relay, "/lists" list history, "/private" drafts). VaultSocket drives
/// it with a WebSocketClient; here it is pure, so it is tested in
/// MediaLogicTests (VaultLinkTests).
///
/// Why kept: a socket per request signed a fresh NIP-42 AUTH every time, and
/// for a bunker owner every AUTH is a remote-signer request. One iPhone sent
/// 2,262 of them to its own vault in three days, ~34 per list change (Logen
/// 2026-11-05). Now a path logs in once and stays logged in; a dropped or
/// stalled socket is reopened by the next request and logs in once more.
///
/// The NIP-42 order with the vault: requests go on connect; the first
/// challenge on a connection is signed, later ones are not. The vault checks
/// each message on its own goroutine, so a request sent right behind the AUTH
/// is refused `auth-required`: that refusal holds the request until the
/// AUTH's OK, then it goes again (the build 54 bug). Requests made while the
/// AUTH is out wait for its OK. Once logged in, one `auth-required` refusal
/// gets one retry; a second ends that request. A refused or unsigned AUTH ends
/// every request on the connection and closes it.
@MainActor
final class VaultLink {
    struct Hooks {
        var connect: () -> Void
        var disconnect: () -> Void
        var send: ([Any]) -> Void
        /// Signs the kind 22242 answer to `challenge` as the owner: its id
        /// and JSON object, or nil when it couldn't be signed.
        var signAuth: (_ challenge: String, _ done: @escaping ((id: String, json: Any)?) -> Void) -> Void
        /// Whether a socket that sat idle is still there (a WebSocket ping).
        var probe: (_ done: @escaping (Bool) -> Void) -> Void
        var after: (_ seconds: TimeInterval, _ run: @escaping () -> Void) -> Void
        var now: () -> Date
    }

    /// A socket quiet this long is pinged before use: one the system killed
    /// while the app was away still looks open.
    static let idleBeforeProbe: TimeInterval = 20

    private enum Conn { case closed, connecting, probing, open }
    private enum Auth: Equatable { case none, signing, sent(String), authed }

    private final class Op {
        let key: String
        let message: [Any]
        let close: [Any]?
        /// True when the request is answered.
        let onMessage: (String, [Any]) -> Bool
        let onFail: () -> Void
        var sent = false
        var retried = false
        init(key: String, message: [Any], close: [Any]?,
             onMessage: @escaping (String, [Any]) -> Bool, onFail: @escaping () -> Void) {
            self.key = key; self.message = message; self.close = close
            self.onMessage = onMessage; self.onFail = onFail
        }
    }

    private let hooks: Hooks
    private var conn: Conn = .closed
    private var auth: Auth = .none
    /// Bumped per connection, so a late signature or probe for an old one is dropped.
    private var generation = 0
    private var ops: [Op] = []
    private var lastHeard = Date.distantPast

    init(hooks: Hooks) { self.hooks = hooks }

    var isLoggedIn: Bool { conn == .open && auth == .authed }

    /// Sends `message` and hands every answer whose second element is `key`
    /// to `onMessage` until it returns true; `close` is sent then (a REQ's
    /// CLOSE). `onFail` instead when the vault refused, the socket dropped or
    /// nothing finished it within `timeout`. Exactly one of the two ends it.
    func perform(key: String, message: [Any], close: [Any]?, timeout: TimeInterval,
                 onMessage: @escaping (String, [Any]) -> Bool, onFail: @escaping () -> Void) {
        let op = Op(key: key, message: message, close: close, onMessage: onMessage, onFail: onFail)
        ops.append(op)
        hooks.after(timeout) { [weak self, weak op] in
            guard let self, let op, self.ops.contains(where: { $0 === op }) else { return }
            // Unanswered: the socket is suspect. Close it; the next request
            // opens a new one (and logs in once).
            self.drop()
        }
        switch conn {
        case .closed: open()
        case .connecting, .probing: break
        case .open:
            if hooks.now().timeIntervalSince(lastHeard) > Self.idleBeforeProbe { probe() } else { send(op) }
        }
    }

    func didConnect() {
        guard conn == .connecting else { return }
        conn = .open
        lastHeard = hooks.now()
        flush()
    }

    /// The socket failed (`error`) or closed. A close reported while a new
    /// socket is still opening is the old one's, and is ignored.
    func didDrop(error: Bool) {
        switch conn {
        case .closed: return
        case .connecting: if error { drop() }
        case .open, .probing: drop()
        }
    }

    func receive(_ text: String) {
        guard conn == .open || conn == .probing,
              let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = arr.first as? String else { return }
        lastHeard = hooks.now()
        if type == "AUTH" {
            if let challenge = arr.count > 1 ? arr[1] as? String : nil { answer(challenge) }
            return
        }
        let key = arr.count > 1 ? arr[1] as? String : nil
        if type == "OK", case .sent(let authID) = auth, key == authID {
            if (arr.count > 2 ? arr[2] as? Bool : nil) == true {
                auth = .authed
                flush()
            } else {
                drop()
            }
            return
        }
        guard let key, let op = ops.first(where: { $0.key == key }) else { return }
        if Self.isAuthRequired(type: type, arr) {
            if auth == .authed {
                if op.retried { end(op, failed: true) } else { op.retried = true; hooks.send(op.message) }
            } else {
                op.sent = false // goes again on the AUTH's OK
            }
            return
        }
        if op.onMessage(type, arr) { end(op, failed: false) }
    }

    /// Closes the socket and ends every request on it.
    func drop() {
        if conn != .closed { hooks.disconnect() }
        conn = .closed
        auth = .none
        generation += 1
        let failed = ops
        ops = []
        failed.forEach { $0.onFail() }
    }

    // MARK: - Private

    private func open() {
        generation += 1
        conn = .connecting
        auth = .none
        for op in ops { op.sent = false; op.retried = false }
        hooks.connect()
    }

    private func probe() {
        conn = .probing
        let gen = generation
        hooks.probe { [weak self] alive in
            guard let self, gen == self.generation, self.conn == .probing else { return }
            if alive {
                self.conn = .open
                self.lastHeard = self.hooks.now()
                self.flush()
            } else {
                // The requests survive: they go on the new socket.
                self.hooks.disconnect()
                self.open()
            }
        }
    }

    private func flush() {
        for op in ops where !op.sent { send(op) }
    }

    private func send(_ op: Op) {
        guard conn == .open else { return }
        switch auth {
        case .signing, .sent: return // goes on the AUTH's OK
        case .none, .authed: break
        }
        op.sent = true
        hooks.send(op.message)
    }

    private func answer(_ challenge: String) {
        guard auth == .none else { return }
        auth = .signing
        let gen = generation
        hooks.signAuth(challenge) { [weak self] signed in
            guard let self, gen == self.generation, self.auth == .signing else { return }
            guard let signed else { self.drop(); return }
            self.auth = .sent(signed.id)
            self.hooks.send(["AUTH", signed.json])
        }
    }

    private func end(_ op: Op, failed: Bool) {
        ops.removeAll { $0 === op }
        if let close = op.close, conn == .open { hooks.send(close) }
        if failed { op.onFail() }
    }

    /// A CLOSED or a refused OK whose reason starts with `auth-required`.
    static func isAuthRequired(type: String, _ arr: [Any]) -> Bool {
        switch type {
        case "CLOSED":
            return (arr.count > 2 ? arr[2] as? String : nil)?.hasPrefix("auth-required") ?? false
        case "OK":
            let accepted = (arr.count > 2 ? arr[2] as? Bool : nil) ?? false
            return !accepted && ((arr.count > 3 ? arr[3] as? String : nil)?.hasPrefix("auth-required") ?? false)
        default:
            return false
        }
    }
}

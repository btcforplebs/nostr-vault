import Foundation
import Combine

/// What a pooled socket is doing, as the pool sees it.
enum LookupSocketState {
    case connecting
    case connected
    /// Refused, timed out or dropped (a 429 included).
    case failed
}

/// The socket under a `LookupSocketPool` entry. `WebSocketClient` in the app
/// (`WebSocketClient+LookupConnection.swift`); a fake in the tests. Frames and
/// states are delivered on the main queue.
protocol LookupConnection: AnyObject {
    var frames: AnyPublisher<String, Never> { get }
    /// Changes after `open`, never the state before it.
    var states: AnyPublisher<LookupSocketState, Never> { get }
    func open(_ url: URL)
    func send(_ text: String)
    func close()
}

/// One socket per relay for the app's small one-shot lookups (profiles,
/// replaceable lists, zap history and the dashboard, live rings), reused
/// across lookups and closed once it has gone quiet. The iPhone/Mac twin of
/// Android's `LookupSocketPool`.
///
/// Each of those lookups used to open its own socket to every relay it asked:
/// at launch a popular relay held up to 12-15 at once, one per owner per call
/// (NV_HEALTH_C3, 11-08). Now:
///  - a relay gets one socket, and every lookup to it is a REQ on that socket
///    under its own subscription id;
///  - REQs sent during the handshake wait for it;
///  - a lookup ends at its EOSE or CLOSED, or at its timeout (then we CLOSE it);
///  - the socket closes `idle` seconds after its last lookup ends;
///  - a relay that refuses or drops the socket gets no new socket for
///    `cooldown` seconds; lookups to it in that time are skipped.
///
/// Main queue only.
final class LookupSocketPool {
    enum Outcome: Equatable {
        /// The relay sent EOSE.
        case eose
        /// The relay sent CLOSED for the subscription.
        case closed
        /// Neither came in time; the subscription was CLOSEd.
        case timeout
        /// The socket was refused or dropped; the relay is cooling down.
        case failed
        /// Not sent: the relay is cooling down, the pool is full, or the
        /// subscription id is already in use on that relay.
        case skipped
        /// The caller ended it (`Lookup.cancel`).
        case cancelled
    }

    /// One lookup on a pooled socket. `cancel` ends it early and CLOSEs it.
    final class Lookup {
        fileprivate let subId: String
        fileprivate let key: String
        fileprivate let endAtEose: Bool
        fileprivate let onMessage: (String) -> Void
        fileprivate let onEnd: ((Outcome) -> Void)?
        fileprivate var timer: DispatchWorkItem?
        fileprivate var ended = false
        fileprivate weak var pool: LookupSocketPool?

        fileprivate init(subId: String, key: String, endAtEose: Bool,
                         onMessage: @escaping (String) -> Void, onEnd: ((Outcome) -> Void)?) {
            self.subId = subId
            self.key = key
            self.endAtEose = endAtEose
            self.onMessage = onMessage
            self.onEnd = onEnd
        }

        func cancel() { pool?.end(self, .cancelled, sendClose: true) }
    }

    private final class Entry {
        let key: String
        let connection: LookupConnection
        var lookups: [String: Lookup] = [:]
        /// Frames waiting for the handshake, in order.
        var pending: [(subId: String, frame: String)] = []
        var connected = false
        var closed = false
        var idleClose: DispatchWorkItem?
        var subscriptions: [AnyCancellable] = []

        init(key: String, connection: LookupConnection) {
            self.key = key
            self.connection = connection
        }
    }

    /// Longer than any lookup window, so a run of lookups keeps the socket.
    static let defaultIdle: TimeInterval = 20
    static let defaultCooldown: TimeInterval = 120
    /// Past this many sockets, lookups to new relays are skipped.
    static let defaultMaxSockets = 32

    private let makeConnection: () -> LookupConnection
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private let now: () -> Date
    private let idle: TimeInterval
    private let cooldown: TimeInterval
    private let maxSockets: Int

    private var entries: [String: Entry] = [:]
    private var cooldownUntil: [String: Date] = [:]
    /// Sockets this pool has dialled since it was made (diagnostics, tests).
    private(set) var socketsOpened = 0

    init(makeConnection: @escaping () -> LookupConnection,
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         now: @escaping () -> Date = Date.init,
         idle: TimeInterval = LookupSocketPool.defaultIdle,
         cooldown: TimeInterval = LookupSocketPool.defaultCooldown,
         maxSockets: Int = LookupSocketPool.defaultMaxSockets) {
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.now = now
        self.idle = idle
        self.cooldown = cooldown
        self.maxSockets = maxSockets
    }

    /// Sockets open right now.
    var openSocketCount: Int { entries.count }

    static func relayKey(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    func isCoolingDown(_ url: URL) -> Bool {
        guard let until = cooldownUntil[Self.relayKey(url)] else { return false }
        return until > now()
    }

    /// Sends `["REQ", subId, ...filters]` to `url` on the relay's pooled
    /// socket and hands every frame for that subscription (EVENT, EOSE,
    /// CLOSED) to `onMessage`, in arrival order, on the main queue. `onEnd`
    /// is called once, after the last frame. With `endAtEose` false the
    /// lookup stays open past EOSE until CLOSED, timeout or `cancel`.
    /// Returns nil when it was not sent (`onEnd` gets `.skipped` first).
    @discardableResult
    func query(url: URL, subId: String, filters: [[String: Any]], timeout: TimeInterval,
               endAtEose: Bool = true,
               onMessage: @escaping (String) -> Void,
               onEnd: ((Outcome) -> Void)? = nil) -> Lookup? {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        guard !filters.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId] + filters),
              let frame = String(data: data, encoding: .utf8),
              let entry = entry(for: url),
              entry.lookups[subId] == nil else {
            onEnd?(.skipped)
            return nil
        }
        let lookup = Lookup(subId: subId, key: entry.key, endAtEose: endAtEose, onMessage: onMessage, onEnd: onEnd)
        lookup.pool = self
        entry.idleClose?.cancel()
        entry.idleClose = nil
        entry.lookups[subId] = lookup
        if entry.connected { entry.connection.send(frame) } else { entry.pending.append((subId, frame)) }
        let timer = DispatchWorkItem { [weak self, weak lookup] in
            guard let self, let lookup else { return }
            self.end(lookup, .timeout, sendClose: true)
        }
        lookup.timer = timer
        schedule(timeout, timer)
        return lookup
    }

    /// Closes every pooled socket (background, account switch). Lookups still
    /// open end as `.failed`; cooldowns are kept and none are added.
    func closeAll() {
        for entry in Array(entries.values) { shut(entry) }
    }

    // MARK: - Internals

    private func entry(for url: URL) -> Entry? {
        let key = Self.relayKey(url)
        if let until = cooldownUntil[key] {
            if until > now() { return nil }
            cooldownUntil[key] = nil
        }
        if let entry = entries[key] { return entry }
        if entries.count >= maxSockets && !evictIdle() { return nil }
        let entry = Entry(key: key, connection: makeConnection())
        entries[key] = entry
        socketsOpened += 1
        entry.connection.frames
            .sink { [weak self, weak entry] frame in
                guard let self, let entry else { return }
                self.dispatch(frame, on: entry)
            }
            .store(in: &entry.subscriptions)
        entry.connection.states
            .sink { [weak self, weak entry] state in
                guard let self, let entry, !entry.closed else { return }
                switch state {
                case .connecting:
                    break
                case .connected:
                    entry.connected = true
                    let queued = entry.pending
                    entry.pending.removeAll()
                    for item in queued { entry.connection.send(item.frame) }
                    if entry.lookups.isEmpty { self.scheduleIdleClose(entry) }
                case .failed:
                    self.cooldownUntil[entry.key] = self.now().addingTimeInterval(self.cooldown)
                    self.shut(entry)
                }
            }
            .store(in: &entry.subscriptions)
        entry.connection.open(url)
        return entry.closed ? nil : entry
    }

    private func dispatch(_ frame: String, on entry: Entry) {
        guard let (type, subId) = Self.route(frame),
              let lookup = entry.lookups[subId], !lookup.ended else { return }
        lookup.onMessage(frame)
        switch type {
        case "EOSE" where lookup.endAtEose: end(lookup, .eose, sendClose: true)
        case "CLOSED": end(lookup, .closed, sendClose: false)
        default: break
        }
    }

    fileprivate func end(_ lookup: Lookup, _ outcome: Outcome, sendClose: Bool) {
        guard !lookup.ended else { return }
        lookup.ended = true
        lookup.timer?.cancel()
        lookup.timer = nil
        if let entry = entries[lookup.key], entry.lookups[lookup.subId] === lookup {
            entry.lookups[lookup.subId] = nil
            let wasPending = entry.pending.contains { $0.subId == lookup.subId }
            entry.pending.removeAll { $0.subId == lookup.subId }
            if sendClose && !wasPending && entry.connected {
                entry.connection.send("[\"CLOSE\",\(Self.quote(lookup.subId))]")
            }
            if entry.lookups.isEmpty { scheduleIdleClose(entry) }
        }
        lookup.onEnd?(outcome)
    }

    private func scheduleIdleClose(_ entry: Entry) {
        entry.idleClose?.cancel()
        let work = DispatchWorkItem { [weak self, weak entry] in
            guard let self, let entry, entry.lookups.isEmpty else { return }
            self.shut(entry)
        }
        entry.idleClose = work
        schedule(idle, work)
    }

    private func evictIdle() -> Bool {
        guard let idle = entries.values.first(where: { $0.lookups.isEmpty }) else { return false }
        shut(idle)
        return true
    }

    private func shut(_ entry: Entry) {
        guard !entry.closed else { return }
        entry.closed = true
        if entries[entry.key] === entry { entries[entry.key] = nil }
        entry.idleClose?.cancel()
        entry.pending.removeAll()
        entry.subscriptions.removeAll()
        let open = Array(entry.lookups.values)
        entry.lookups.removeAll()
        entry.connection.close()
        for lookup in open where !lookup.ended {
            lookup.ended = true
            lookup.timer?.cancel()
            lookup.onEnd?(.failed)
        }
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Message type and subscription id of a relay frame like
    /// `["EVENT","sub",{...}]`, read without parsing the event.
    static func route(_ frame: String) -> (type: String, subId: String)? {
        let chars = Array(frame.utf8.prefix(256))
        var i = 0
        func skip() { while i < chars.count, [0x20, 0x2C, 0x0A, 0x09, 0x0D].contains(chars[i]) { i += 1 } }
        func string() -> String? {
            skip()
            guard i < chars.count, chars[i] == 0x22 else { return nil }
            i += 1
            var out: [UInt8] = []
            while i < chars.count {
                let c = chars[i]
                if c == 0x22 { i += 1; return String(decoding: out, as: UTF8.self) }
                if c == 0x5C {
                    guard i + 1 < chars.count else { return nil }
                    out.append(chars[i + 1]); i += 2
                } else {
                    out.append(c); i += 1
                }
            }
            return nil
        }
        skip()
        guard i < chars.count, chars[i] == 0x5B else { return nil }
        i += 1
        guard let type = string(), let subId = string() else { return nil }
        return (type, subId)
    }
}

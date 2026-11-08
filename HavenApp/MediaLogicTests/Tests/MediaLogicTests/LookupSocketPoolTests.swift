import XCTest
import Combine
@testable import MediaLogic

/// NV_HEALTH_C3 (11-08): every small lookup opened its own socket per relay,
/// so a popular relay held 12-15 at launch. The pool gives each relay one.
final class LookupSocketPoolTests: XCTestCase {
    private final class FakeSocket: LookupConnection {
        let frameSubject = PassthroughSubject<String, Never>()
        let stateSubject = PassthroughSubject<LookupSocketState, Never>()
        var frames: AnyPublisher<String, Never> { frameSubject.eraseToAnyPublisher() }
        var states: AnyPublisher<LookupSocketState, Never> { stateSubject.eraseToAnyPublisher() }
        var opened: URL?
        var sent: [String] = []
        var closed = false
        func open(_ url: URL) { opened = url; stateSubject.send(.connecting) }
        func send(_ text: String) { sent.append(text) }
        func close() { closed = true }
        func connect() { stateSubject.send(.connected) }
        func reply(_ frame: String) { frameSubject.send(frame) }
        var reqIds: [String] { sent.compactMap { LookupSocketPool.route($0) }.filter { $0.type == "REQ" }.map(\.subId) }
        var closeIds: [String] { sent.compactMap { LookupSocketPool.route($0) }.filter { $0.type == "CLOSE" }.map(\.subId) }
    }

    /// A clock the test moves by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var due: [(at: Date, work: DispatchWorkItem)] = []
        func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem) { due.append((now.addingTimeInterval(delay), work)) }
        func advance(_ seconds: TimeInterval) {
            let end = now.addingTimeInterval(seconds)
            while let next = due.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
                due.remove(at: next.offset)
                now = next.element.at
                if !next.element.work.isCancelled { next.element.work.perform() }
            }
            now = end
        }
    }

    private var sockets: [FakeSocket] = []
    private var clock = Clock()

    private func makePool(maxSockets: Int = 32) -> LookupSocketPool {
        sockets = []
        clock = Clock()
        return LookupSocketPool(
            makeConnection: { [unowned self] in let s = FakeSocket(); self.sockets.append(s); return s },
            schedule: { [unowned self] delay, work in self.clock.schedule(delay, work) },
            now: { [unowned self] in self.clock.now },
            idle: 20, cooldown: 120, maxSockets: maxSockets)
    }

    private let damus = URL(string: "wss://relay.damus.io")!
    private let primal = URL(string: "wss://relay.primal.net")!
    private let filter: [[String: Any]] = [["kinds": [0], "authors": ["ab"]]]

    func testLookupsToOneRelayShareOneSocket() {
        let pool = makePool()
        // The dashboard's notes, listings and live queries, plus a profile
        // batch and a live ring, all at launch.
        for id in ["zaphist-a", "zaphist-b", "zaphist-c", "meta-1", "ring-1"] {
            pool.query(url: damus, subId: id, filters: filter, timeout: 5, onMessage: { _ in })
        }
        // Same relay spelled with a trailing slash.
        pool.query(url: URL(string: "wss://relay.damus.io/")!, subId: "repl-1", filters: filter, timeout: 5, onMessage: { _ in })
        pool.query(url: primal, subId: "zaphist-a", filters: filter, timeout: 5, onMessage: { _ in })
        XCTAssertEqual(sockets.count, 2, "one socket per relay")
        XCTAssertEqual(pool.socketsOpened, 2)
        sockets[0].connect()
        XCTAssertEqual(sockets[0].reqIds, ["zaphist-a", "zaphist-b", "zaphist-c", "meta-1", "ring-1", "repl-1"],
                       "REQs wait for the handshake, then go out in order")
        XCTAssertEqual(sockets[1].reqIds, [], "primal is still connecting")
    }

    func testFramesGoOnlyToTheirLookupAndEOSEEndsIt() {
        let pool = makePool()
        var a: [String] = [], b: [String] = []
        var endA: LookupSocketPool.Outcome?
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { a.append($0) }, onEnd: { endA = $0 })
        pool.query(url: damus, subId: "b", filters: filter, timeout: 5, onMessage: { b.append($0) })
        let socket = sockets[0]
        socket.connect()
        socket.reply(#"["EVENT","a",{"id":"1"}]"#)
        socket.reply(#"["EVENT", "b", {"id":"2"}]"#)
        socket.reply(#"["EOSE","a"]"#)
        socket.reply(#"["EVENT","a",{"id":"late"}]"#)
        XCTAssertEqual(a, [#"["EVENT","a",{"id":"1"}]"#, #"["EOSE","a"]"#], "the EOSE is passed on, nothing after it")
        XCTAssertEqual(b, [#"["EVENT", "b", {"id":"2"}]"#])
        XCTAssertEqual(endA, .eose)
        XCTAssertEqual(socket.closeIds, ["a"])
        XCTAssertFalse(socket.closed, "b still uses the socket")
    }

    func testClosedEndsWithoutSendingClose() {
        let pool = makePool()
        var end: LookupSocketPool.Outcome?
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in }, onEnd: { end = $0 })
        sockets[0].connect()
        sockets[0].reply(#"["CLOSED","a","rate-limited"]"#)
        XCTAssertEqual(end, .closed)
        XCTAssertEqual(sockets[0].closeIds, [])
    }

    func testTimeoutClosesTheSubscription() {
        let pool = makePool()
        var end: LookupSocketPool.Outcome?
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in }, onEnd: { end = $0 })
        sockets[0].connect()
        clock.advance(4.9)
        XCTAssertNil(end)
        clock.advance(0.2)
        XCTAssertEqual(end, .timeout)
        XCTAssertEqual(sockets[0].closeIds, ["a"])
    }

    func testCancelBeforeTheHandshakeSendsNothing() {
        let pool = makePool()
        let lookup = pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in })
        lookup?.cancel()
        sockets[0].connect()
        XCTAssertEqual(sockets[0].sent, [])
    }

    func testSocketIsReusedUntilIdleThenClosed() {
        let pool = makePool()
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in })
        sockets[0].connect()
        sockets[0].reply(#"["EOSE","a"]"#)
        clock.advance(15)
        pool.query(url: damus, subId: "b", filters: filter, timeout: 5, onMessage: { _ in })
        XCTAssertEqual(sockets.count, 1, "a lookup inside the idle window reuses the socket")
        XCTAssertEqual(sockets[0].reqIds, ["a", "b"])
        sockets[0].reply(#"["EOSE","b"]"#)
        clock.advance(19)
        XCTAssertFalse(sockets[0].closed)
        clock.advance(2)
        XCTAssertTrue(sockets[0].closed, "closed 20 s after its last lookup")
        XCTAssertEqual(pool.openSocketCount, 0)
        pool.query(url: damus, subId: "c", filters: filter, timeout: 5, onMessage: { _ in })
        XCTAssertEqual(sockets.count, 2, "the next lookup dials again")
    }

    func testARefusedRelayCoolsDown() {
        let pool = makePool()
        var ends: [LookupSocketPool.Outcome] = []
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in }, onEnd: { ends.append($0) })
        sockets[0].stateSubject.send(.failed)  // 429 at the upgrade
        XCTAssertEqual(ends, [.failed])
        XCTAssertTrue(pool.isCoolingDown(damus))
        XCTAssertNil(pool.query(url: damus, subId: "b", filters: filter, timeout: 5, onMessage: { _ in }, onEnd: { ends.append($0) }))
        XCTAssertEqual(ends, [.failed, .skipped])
        XCTAssertEqual(sockets.count, 1, "no new socket while cooling down")
        clock.advance(121)
        pool.query(url: damus, subId: "c", filters: filter, timeout: 5, onMessage: { _ in })
        XCTAssertEqual(sockets.count, 2)
    }

    func testDuplicateSubIdOnOneRelayIsSkipped() {
        let pool = makePool()
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in })
        var end: LookupSocketPool.Outcome?
        XCTAssertNil(pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in }, onEnd: { end = $0 }))
        XCTAssertEqual(end, .skipped)
    }

    func testCapEvictsAnIdleSocketOrSkips() {
        let pool = makePool(maxSockets: 2)
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in })
        pool.query(url: primal, subId: "a", filters: filter, timeout: 5, onMessage: { _ in })
        let third = URL(string: "wss://nos.lol")!
        XCTAssertNil(pool.query(url: third, subId: "a", filters: filter, timeout: 5, onMessage: { _ in }), "both busy")
        sockets[0].connect()
        sockets[0].reply(#"["EOSE","a"]"#)
        XCTAssertNotNil(pool.query(url: third, subId: "a", filters: filter, timeout: 5, onMessage: { _ in }))
        XCTAssertTrue(sockets[0].closed, "the idle one made room")
        XCTAssertEqual(pool.openSocketCount, 2)
    }

    func testCloseAllFailsOpenLookupsWithoutCooldown() {
        let pool = makePool()
        var end: LookupSocketPool.Outcome?
        pool.query(url: damus, subId: "a", filters: filter, timeout: 5, onMessage: { _ in }, onEnd: { end = $0 })
        pool.closeAll()
        XCTAssertEqual(end, .failed)
        XCTAssertTrue(sockets[0].closed)
        XCTAssertFalse(pool.isCoolingDown(damus))
    }

    func testRouteReadsTypeAndSubIdOnly() {
        XCTAssertEqual(LookupSocketPool.route(#"["EVENT","meta-1",{"id":"x"}]"#)?.subId, "meta-1")
        XCTAssertEqual(LookupSocketPool.route(" [ \"EOSE\" ,\n\"a\\\"b\"]")?.subId, "a\"b")
        XCTAssertEqual(LookupSocketPool.route(#"["NOTICE","slow down"]"#)?.type, "NOTICE")
        XCTAssertNil(LookupSocketPool.route(#"{"EVENT":1}"#))
        XCTAssertNil(LookupSocketPool.route(#"["EOSE"]"#))
    }

    /// The small lookups ride the pool instead of dialling their own sockets.
    func testSmallLookupsUseThePool() throws {
        let services = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../HavenApp/Services").standardized
        func source(_ path: String) throws -> String {
            try String(contentsOf: services.appendingPathComponent(path), encoding: .utf8)
        }
        for path in ["ZapHistoryService.swift", "LiveStatusService.swift", "Nostr/NostrService+Profiles.swift"] {
            let src = try source(path)
            XCTAssertFalse(src.contains("WebSocketClient()"), "\(path) opens its own sockets")
            XCTAssertTrue(src.contains("LookupSocketPool.shared.query("), path)
        }
        // The pool is main queue only, and a nonisolated async func runs off
        // main: the zap query must be pinned to the main actor.
        XCTAssertTrue(try source("ZapHistoryService.swift").contains("@MainActor\n    static func query(filters:"),
                      "ZapHistoryService.query touches the pool off the main queue")
        let lookups = try source("Nostr/NostrService+Lookups.swift")
        let start = try XCTUnwrap(lookups.range(of: "func lookupNewestReplaceable("))
        let end = try XCTUnwrap(lookups.range(of: "func fetchRecentNotes(", range: start.upperBound..<lookups.endIndex))
        let body = lookups[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(body.contains("WebSocketClient()"), "lookupNewestReplaceable opens its own sockets")
        XCTAssertTrue(body.contains("LookupSocketPool.shared.query("))
    }
}

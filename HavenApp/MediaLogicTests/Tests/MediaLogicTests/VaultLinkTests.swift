import XCTest
@testable import MediaLogic

/// VaultLink against a fake vault that behaves like haven-go's: a challenge
/// on connect, `auth-required` until the AUTH's OK, and that refusal for a
/// REQ that arrives before the AUTH is processed. The counts are of AUTHs
/// signed, which for a bunker owner are remote-signer requests.
@MainActor
final class VaultLinkTests: XCTestCase {
    /// A fake vault. Its replies queue up and `pump()` delivers them, so
    /// nothing re-enters the link mid-call.
    @MainActor
    final class FakeVault {
        var signs = 0
        var connects = 0
        var sent: [[Any]] = []
        var authed = false
        var alive = true
        var refuseAuth = false
        var signerAnswers = true
        var events = 3
        var timers: [() -> Void] = []
        var clock = Date(timeIntervalSince1970: 1_000_000)
        private var queue: [() -> Void] = []
        weak var link: VaultLink?

        var hooks: VaultLink.Hooks {
            .init(
                connect: { [unowned self] in
                    connects += 1
                    authed = false
                    queue.append { [unowned self] in
                        link?.didConnect()
                        link?.receive(#"["AUTH","chal-\#(connects)"]"#)
                    }
                },
                disconnect: {},
                send: { [unowned self] msg in sent.append(msg); reply(to: msg) },
                signAuth: { [unowned self] challenge, done in
                    signs += 1
                    let answers = signerAnswers
                    let id = "auth-\(signs)"
                    queue.append { done(answers ? (id, ["id": id, "kind": 22242, "challenge": challenge]) : nil) }
                },
                probe: { [unowned self] done in let a = alive; queue.append { done(a) } },
                after: { [unowned self] _, run in timers.append(run) },
                now: { [unowned self] in clock }
            )
        }

        private func reply(to msg: [Any]) {
            guard let type = msg.first as? String, msg.count > 1 else { return }
            switch type {
            case "AUTH":
                let id = ((msg[1] as? [String: Any])?["id"] as? String) ?? ""
                let ok = !refuseAuth
                queue.append { [unowned self] in
                    authed = ok
                    deliver(["OK", id, ok, ok ? "" : "restricted: not the owner"])
                }
            case "REQ":
                let sub = msg[1] as! String
                if !authed { queue.append { [unowned self] in deliver(["CLOSED", sub, "auth-required: log in"]) }; return }
                let n = events
                queue.append { [unowned self] in
                    for i in 0..<n { deliver(["EVENT", sub, ["id": "e\(i)"]]) }
                    deliver(["EOSE", sub])
                }
            case "EVENT":
                let id = ((msg[1] as? [String: Any])?["id"] as? String) ?? ""
                let ok = authed
                queue.append { [unowned self] in deliver(["OK", id, ok, ok ? "" : "auth-required: log in"]) }
            default: break
            }
        }

        func deliver(_ arr: [Any]) {
            let data = try! JSONSerialization.data(withJSONObject: arr)
            link?.receive(String(data: data, encoding: .utf8)!)
        }

        func pump() {
            while !queue.isEmpty { queue.removeFirst()() }
        }

        func fireTimers() {
            let t = timers; timers = []; t.forEach { $0() }
        }

        func requests() -> Int { sent.filter { ($0.first as? String) == "REQ" }.count }
    }

    private func makeLink(_ vault: FakeVault) -> VaultLink {
        let link = VaultLink(hooks: vault.hooks)
        vault.link = link
        return link
    }

    /// A query as VaultSocket makes it: the event count, or nil.
    private func query(_ link: VaultLink, _ filters: [[String: Any]] = [["kinds": [3]]],
                       into results: inout [Int?], at index: Int) {
        let sub = "s\(index)"
        var count = 0
        results.append(-1)
        let box = Box()
        link.perform(key: sub, message: ["REQ", sub] + filters, close: ["CLOSE", sub], timeout: 8,
                     onMessage: { type, _ in
                         if type == "EVENT" { count += 1; return false }
                         if type == "EOSE" { box.value = count; box.done = true; return true }
                         if type == "CLOSED" { box.value = nil; box.done = true; return true }
                         return false
                     },
                     onFail: { box.value = nil; box.done = true })
        boxes.append(box)
    }

    final class Box { var value: Int?; var done = false }
    private var boxes: [Box] = []

    private func run(_ n: Int, on link: VaultLink, _ vault: FakeVault) -> [Int?] {
        var ignored: [Int?] = []
        boxes = []
        for i in 0..<n { query(link, into: &ignored, at: i) }
        vault.pump()
        XCTAssertTrue(boxes.allSatisfy(\.done))
        return boxes.map(\.value)
    }

    // MARK: - The count

    /// What the iPhone did: one wipe check read /lists once and then once per
    /// protected kind (17 reads), each on its own socket, so 17 AUTHs signed.
    /// Kept: the same 17 reads sign one.
    func testSeventeenReadsSignOnceOnAKeptSocketNotSeventeen() {
        let before = FakeVault()
        for i in 0..<17 {
            let link = makeLink(before) // a socket per request, as before
            var r: [Int?] = []
            boxes = []
            query(link, into: &r, at: i)
            before.pump()
            XCTAssertEqual(boxes.first?.value, 3)
        }
        XCTAssertEqual(before.signs, 17)

        let after = FakeVault()
        let link = makeLink(after)
        for _ in 0..<17 {
            XCTAssertEqual(run(1, on: link, after), [3])
        }
        XCTAssertEqual(after.signs, 1)
        XCTAssertEqual(after.connects, 1)
    }

    /// Requests made together before the socket is up share one login.
    func testConcurrentRequestsShareOneLogin() {
        let vault = FakeVault()
        let link = makeLink(vault)
        XCTAssertEqual(run(5, on: link, vault), [3, 3, 3, 3, 3])
        XCTAssertEqual(vault.signs, 1)
        XCTAssertTrue(link.isLoggedIn)
    }

    /// Per-kind filters ride one REQ (the wipe check): one request, one AUTH.
    func testPerKindFiltersAreOneRequest() {
        let vault = FakeVault()
        let link = makeLink(vault)
        let filters = (0..<16).map { ["kinds": [$0], "limit": 1000] as [String: Any] }
        var r: [Int?] = []
        boxes = []
        query(link, filters, into: &r, at: 0)
        vault.pump()
        XCTAssertEqual(boxes.first?.value, 3)
        XCTAssertEqual(vault.signs, 1)
        // The first REQ was refused before the login and went again once.
        XCTAssertEqual(vault.requests(), 2)
        XCTAssertEqual((vault.sent.last(where: { ($0.first as? String) == "REQ" }) ?? []).count, 18)
    }

    /// A finished query closes its subscription on the kept socket.
    func testFinishedQueryIsClosed() {
        let vault = FakeVault()
        let link = makeLink(vault)
        _ = run(1, on: link, vault)
        XCTAssertEqual(vault.sent.last?.first as? String, "CLOSE")
        XCTAssertEqual(vault.sent.last?[1] as? String, "s0")
    }

    // MARK: - Reconnect logs in once

    func testDroppedSocketReconnectsAndLogsInOnce() {
        let vault = FakeVault()
        let link = makeLink(vault)
        _ = run(2, on: link, vault)
        link.didDrop(error: true)
        XCTAssertEqual(run(3, on: link, vault), [3, 3, 3])
        XCTAssertEqual(vault.signs, 2)
        XCTAssertEqual(vault.connects, 2)
    }

    /// The old socket's close, reported while the new one opens, is not a drop.
    func testCloseWhileConnectingIsIgnored() {
        let vault = FakeVault()
        let link = makeLink(vault)
        var r: [Int?] = []
        boxes = []
        query(link, into: &r, at: 0)
        link.didDrop(error: false)
        vault.pump()
        XCTAssertEqual(boxes.first?.value, 3)
        XCTAssertEqual(vault.connects, 1)
    }

    /// A socket idle past the probe window is pinged first: alive, it is
    /// reused with no new login; dead, it is reopened with exactly one.
    func testIdleSocketIsProbed() {
        let vault = FakeVault()
        let link = makeLink(vault)
        _ = run(1, on: link, vault)
        vault.clock += VaultLink.idleBeforeProbe + 1
        XCTAssertEqual(run(1, on: link, vault), [3])
        XCTAssertEqual(vault.signs, 1)

        vault.clock += VaultLink.idleBeforeProbe + 1
        vault.alive = false
        XCTAssertEqual(run(2, on: link, vault), [3, 3])
        XCTAssertEqual(vault.signs, 2)
        XCTAssertEqual(vault.connects, 2)
    }

    /// An unanswered request closes the socket; the next one reopens it.
    func testTimeoutDropsTheSocket() {
        let vault = FakeVault()
        let link = makeLink(vault)
        _ = run(1, on: link, vault)
        vault.timers = []
        var r: [Int?] = []
        boxes = []
        query(link, into: &r, at: 9) // never pumped: no answer
        vault.fireTimers()
        XCTAssertTrue(boxes[0].done)
        XCTAssertNil(boxes[0].value)
        XCTAssertFalse(link.isLoggedIn)
        XCTAssertEqual(run(1, on: link, vault), [3])
        XCTAssertEqual(vault.signs, 2)
    }

    /// Timers of requests already answered change nothing.
    func testAnsweredTimersAreHarmless() {
        let vault = FakeVault()
        let link = makeLink(vault)
        _ = run(3, on: link, vault)
        vault.fireTimers()
        XCTAssertTrue(link.isLoggedIn)
    }

    // MARK: - Refusals (the old VaultAuthGate cases)

    func testRefusedAuthFailsEveryRequest() {
        let vault = FakeVault()
        vault.refuseAuth = true
        let link = makeLink(vault)
        XCTAssertEqual(run(2, on: link, vault), [nil, nil])
        XCTAssertFalse(link.isLoggedIn)
    }

    /// The signer couldn't sign (bunker not connected): fail now, and the
    /// next request tries a new login rather than waiting on a dead one.
    func testUnsignedAuthFailsAndNextRequestTriesAgain() {
        let vault = FakeVault()
        vault.signerAnswers = false
        let link = makeLink(vault)
        XCTAssertEqual(run(1, on: link, vault), [nil])
        vault.signerAnswers = true
        XCTAssertEqual(run(1, on: link, vault), [3])
        XCTAssertEqual(vault.signs, 2)
    }

    /// Only the first challenge on a connection is signed.
    func testSecondChallengeIsNotSigned() {
        let vault = FakeVault()
        let link = makeLink(vault)
        _ = run(1, on: link, vault)
        vault.deliver(["AUTH", "again"])
        vault.pump()
        XCTAssertEqual(vault.signs, 1)
    }

    /// Logged in, one auth-required refusal gets one retry, a second fails.
    func testOneRetryAfterLoginThenFail() {
        let vault = FakeVault()
        let link = makeLink(vault)
        _ = run(1, on: link, vault)
        vault.sent = []
        vault.authed = false // the vault forgot us
        let box = Box()
        link.perform(key: "x", message: ["REQ", "x", ["kinds": [3]]], close: nil, timeout: 8,
                     onMessage: { _, _ in box.value = 1; box.done = true; return true },
                     onFail: { box.value = nil; box.done = true })
        vault.pump()
        // auth-required once: sent again; twice: failed.
        XCTAssertEqual(vault.requests(), 2)
        XCTAssertTrue(box.done)
        XCTAssertNil(box.value)
        XCTAssertEqual(vault.signs, 1)
    }

    /// A publish refused before the login goes again on the AUTH's OK.
    func testPublishBeforeLoginWaitsForIt() {
        let vault = FakeVault()
        let link = makeLink(vault)
        var accepted: Bool?
        link.perform(key: "ev1", message: ["EVENT", ["id": "ev1"]], close: nil, timeout: 6,
                     onMessage: { type, arr in
                         guard type == "OK" else { return false }
                         accepted = arr[2] as? Bool
                         return true
                     },
                     onFail: { accepted = false })
        vault.pump()
        XCTAssertEqual(accepted, true)
        XCTAssertEqual(vault.signs, 1)
    }

    func testAuthRequiredReasons() {
        XCTAssertTrue(VaultLink.isAuthRequired(type: "CLOSED", ["CLOSED", "s", "auth-required: x"]))
        XCTAssertTrue(VaultLink.isAuthRequired(type: "OK", ["OK", "e", false, "auth-required: x"]))
        XCTAssertFalse(VaultLink.isAuthRequired(type: "OK", ["OK", "e", false, "blocked: no"]))
        XCTAssertFalse(VaultLink.isAuthRequired(type: "OK", ["OK", "e", true, "auth-required: x"]))
        XCTAssertFalse(VaultLink.isAuthRequired(type: "CLOSED", ["CLOSED", "s", "error: boom"]))
    }
}

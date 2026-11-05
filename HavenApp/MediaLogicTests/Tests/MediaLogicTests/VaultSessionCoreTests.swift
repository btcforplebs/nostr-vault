import XCTest
@testable import MediaLogic

/// A vault as khatru runs it: a challenge on every new connection; a REQ or
/// EVENT before the login is refused `auth-required`; the AUTH gets an OK.
/// Counts the logins it was sent, which is what a remote signer pays for.
private final class FakeVault {
    struct Version { let id: String; let kind: Int; let createdAt: Int }
    var versions: [Version] = []
    var logins = 0
    var connections = 0
    private var authed = false
    private var challengeCount = 0

    func connect() -> [[Any]] {
        connections += 1
        authed = false
        challengeCount += 1
        return [["AUTH", "challenge-\(challengeCount)"]]
    }

    func receive(_ text: String) -> [[Any]] {
        guard let arr = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              let type = arr.first as? String else { return [] }
        switch type {
        case "AUTH":
            logins += 1
            authed = true
            let id = (arr[1] as? [String: Any])?["id"] as? String ?? ""
            return [["OK", id, true, ""]]
        case "REQ":
            let sub = arr[1] as! String
            guard authed else { return [["CLOSED", sub, "auth-required: log in"]] }
            let f = arr[2] as! [String: Any]
            let kinds = Set(f["kinds"] as? [Int] ?? [])
            let until = f["until"] as? Int ?? Int.max
            let limit = f["limit"] as? Int ?? Int.max
            // `#v` asks for the versions an import filed: none here.
            if f["#v"] != nil { return [["EOSE", sub]] }
            let hits = versions.filter { kinds.contains($0.kind) && $0.createdAt <= until }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
            return hits.map { ["EVENT", sub, ["id": $0.id, "kind": $0.kind, "created_at": $0.createdAt]] } + [["EOSE", sub]]
        case "EVENT":
            let id = (arr[1] as? [String: Any])?["id"] as? String ?? ""
            guard authed else { return [["OK", id, false, "auth-required: log in"]] }
            return [["OK", id, true, ""]]
        default:
            return []
        }
    }
}

/// Runs requests through VaultSessionCore against the fake, effects applied
/// at once (as VaultSocket does on the main actor).
private final class Driver {
    let vault: FakeVault
    var core = VaultSessionCore()
    var results: [String: VaultSessionCore.Outcome] = [:]
    private var authN = 0

    init(_ vault: FakeVault) { self.vault = vault }

    func apply(_ effects: [VaultSessionCore.Effect]) {
        for effect in effects {
            switch effect {
            case .connect:
                apply(core.connected())
                for m in vault.connect() { apply(core.received(type: m[0] as! String, m)) }
            case .disconnect:
                apply(core.disconnected())
            case .send(let text):
                for m in vault.receive(text) { apply(core.received(type: m[0] as! String, m)) }
            case .signAuth(let challenge):
                authN += 1
                let id = "auth-\(authN)"
                let frame = String(data: try! JSONSerialization.data(withJSONObject: ["AUTH", ["id": id, "kind": 22242, "challenge": challenge]]), encoding: .utf8)!
                apply(core.authSigned(id: id, frame: frame))
            case .finish(let key, let outcome):
                results[key] = outcome
            }
        }
    }

    /// One REQ; its events' (id, created_at).
    func query(_ filter: [String: Any]) -> [(id: String, createdAt: Int)]? {
        let sub = "s\(results.count)-\(UUID().uuidString.prefix(4))"
        let frame = String(data: try! JSONSerialization.data(withJSONObject: ["REQ", sub, filter]), encoding: .utf8)!
        apply(core.submit(key: sub, kind: .req, frame: frame).effects)
        guard case .events(let raw)? = results[sub] else { return nil }
        return raw.map { obj in
            let d = obj as! [String: Any]
            return (d["id"] as! String, d["created_at"] as! Int)
        }
    }

    /// VaultSocket.queryAll: paged with VaultPaging.
    func queryAll(_ filter: [String: Any]) -> Int {
        var page = filter
        page["limit"] = VaultPaging.limit
        var seen = Set<String>()
        for _ in 0..<VaultPaging.maxPages {
            guard let found = query(page) else { return -1 }
            let known = seen
            found.forEach { seen.insert($0.id) }
            guard let until = VaultPaging.nextUntil(page: found, known: known) else { break }
            page["until"] = until
        }
        return seen.count
    }
}

final class VaultSessionCoreTests: XCTestCase {
    private let protectedKinds = [0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007,
                                  10015, 10030, 10050, 10063, 30000, 30002, 30003]

    /// Logen's shape: 1,300 versions of his follow list, a few of the rest.
    private func logensVault() -> FakeVault {
        let v = FakeVault()
        var t = 2_000_000_000
        for i in 0..<1300 { v.versions.append(.init(id: "k3-\(i)", kind: 3, createdAt: t)); t -= 60 }
        for kind in [0, 10002, 10003, 10063] {
            for i in 0..<5 { v.versions.append(.init(id: "k\(kind)-\(i)", kind: kind, createdAt: t)); t -= 60 }
        }
        return v
    }

    /// The old code, as it was: a new socket (so a new login) per REQ, and a
    /// re-ask per kind whenever the first answer came back full.
    private func oldRead(_ vault: FakeVault, kinds: [Int], imported: Bool = false) -> Int {
        func oneSocket(_ kinds: [Int]) -> [(id: String, createdAt: Int)] {
            var f: [String: Any] = ["kinds": kinds, "limit": 1000]
            if imported { f["#v"] = ["imported"] }
            return Driver(vault).query(f) ?? []
        }
        let found = oneSocket(kinds)
        guard found.count >= 1000 else { return found.count }
        return kinds.reduce(0) { $0 + oneSocket([$1]).count }
    }

    /// One list change (a kind 3 saved): the wipe check reads that kind, then
    /// the List backups banner reads every kind, own and imported.
    /// Before: 20 logins (Logen's log: ~17 /lists logins in 20 s). After: 1.
    func testOneListChangeLogsInOnce() {
        let before = logensVault()
        _ = oldRead(before, kinds: [3])                 // ListWipeWatcher.check
        _ = oldRead(before, kinds: protectedKinds)      // ListBackupService: own
        _ = oldRead(before, kinds: protectedKinds, imported: true) // ListBackupService: imported
        XCTAssertEqual(before.logins, 2 + 17 + 1, "positive control: the old per-request login")

        let after = logensVault()
        let d = Driver(after)
        XCTAssertEqual(d.queryAll(["kinds": [3]]), 1300)
        XCTAssertEqual(d.queryAll(["kinds": protectedKinds]), 1320)
        _ = d.queryAll(["kinds": protectedKinds, "#v": ["imported"]])
        XCTAssertEqual(after.logins, 1, "one list change logged in \(after.logins) times on one session")
        XCTAssertEqual(after.connections, 1)
    }

    /// The app comes forward with 6 accounts. Before: every account's lists
    /// (each a full read), then the banner (own + imported): 6 × 17 + 17 + 1
    /// = 120 logins. After:
    /// the active account only, on the open session: 1 (0 if it is still open).
    func testOneForegroundLogsInOnce() {
        let before = logensVault()
        for _ in 0..<6 { _ = oldRead(before, kinds: protectedKinds) }
        _ = oldRead(before, kinds: protectedKinds)
        _ = oldRead(before, kinds: protectedKinds, imported: true)
        XCTAssertEqual(before.logins, 6 * 17 + 17 + 1)

        let after = logensVault()
        let d = Driver(after)
        _ = d.queryAll(["kinds": protectedKinds])      // the active account's check
        _ = d.queryAll(["kinds": protectedKinds])      // banner: own
        _ = d.queryAll(["kinds": protectedKinds, "#v": ["imported"]]) // banner: imported
        XCTAssertEqual(after.logins, 1)
    }

    /// Paging reads every version (the reason the old code re-asked per kind:
    /// a pinned pre-wipe copy past the cap; Tron, PR 1568).
    func testPagingReadsPastTheCap() {
        let v = logensVault()
        XCTAssertEqual(Driver(v).queryAll(["kinds": protectedKinds]), v.versions.count)
    }

    /// Requests made while the login is being signed wait for its OK; none is
    /// sent into a refusal.
    func testRequestsWaitForTheLoginsOK() {
        var core = VaultSessionCore()
        XCTAssertEqual(core.submit(key: "a", kind: .req, frame: "A").effects.count, 1) // connect
        _ = core.connected()
        let challenge = core.received(type: "AUTH", ["AUTH", "c1"])
        guard case .signAuth = challenge.first else { return XCTFail("challenge not answered") }
        XCTAssertTrue(core.submit(key: "b", kind: .req, frame: "B").effects.isEmpty, "sent while signing")
        _ = core.authSigned(id: "x", frame: "AUTHFRAME")
        let onOK = core.received(type: "OK", ["OK", "x", true, ""])
        let sent = onOK.compactMap { if case .send(let t) = $0 { return t } else { return nil } }
        XCTAssertTrue(sent.contains("B"))
    }

    /// After the login, one `auth-required` refusal gets one retry; a second
    /// fails and closes the socket (its login is no good), so the next
    /// request logs in afresh instead of failing on it too (Tron, PR 1739).
    func testOneRetryAfterTheLogin() {
        var core = VaultSessionCore()
        _ = core.submit(key: "a", kind: .req, frame: "A")
        _ = core.connected()
        _ = core.received(type: "AUTH", ["AUTH", "c1"])
        _ = core.authSigned(id: "x", frame: "AF")
        _ = core.received(type: "OK", ["OK", "x", true, ""])
        let first = core.received(type: "CLOSED", ["CLOSED", "a", "auth-required: again"])
        guard case .send("A")? = first.first else { return XCTFail("no retry") }
        let second = core.received(type: "CLOSED", ["CLOSED", "a", "auth-required: again"])
        XCTAssertFalse(second.contains { if case .send = $0 { return true } else { return false } }, "retried twice")
        guard case .disconnect? = second.first else { return XCTFail("refused socket kept") }
        XCTAssertTrue(second.contains { if case .finish("a", .failed) = $0 { return true } else { return false } })
        guard case .connect? = core.submit(key: "b", kind: .req, frame: "B").effects.first else { return XCTFail("no new socket") }
    }

    /// A refused login, or none could be signed: the socket closes and
    /// whatever waited fails; the next request starts over (and logs in).
    func testRefusedLoginClosesTheSocket() {
        var core = VaultSessionCore()
        _ = core.submit(key: "a", kind: .req, frame: "A")
        _ = core.connected()
        _ = core.received(type: "AUTH", ["AUTH", "c1"])
        let none = core.authUnavailable()
        guard case .disconnect? = none.first else { return XCTFail("socket kept") }
        XCTAssertTrue(core.isIdle)
        guard case .connect? = core.submit(key: "b", kind: .req, frame: "B").effects.first else { return XCTFail("no new socket") }
    }

    /// A dropped socket fails what was asked on it; the next request reconnects.
    func testDropFailsWaitersAndReconnects() {
        let v = logensVault()
        let d = Driver(v)
        _ = d.query(["kinds": [0], "limit": 5])
        d.apply(d.core.disconnected())
        _ = d.query(["kinds": [0], "limit": 5])
        XCTAssertEqual(v.connections, 2)
        XCTAssertEqual(v.logins, 2)
    }

    /// A REQ's subscription is closed on the vault at its EOSE: the socket
    /// stays open, so it must not pile up subscriptions.
    func testEOSEClosesTheSubscription() {
        var core = VaultSessionCore()
        _ = core.submit(key: "s1", kind: .req, frame: "R")
        _ = core.connected()
        let out = core.received(type: "EOSE", ["EOSE", "s1"])
        let sent = out.compactMap { if case .send(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(sent, [VaultSessionCore.closeFrame("s1")])
    }

    /// A socket iOS killed while the app was away still reads connected:
    /// a request on it hears nothing at all. Its timeout closes the socket,
    /// so the next request opens a new one rather than also timing out.
    func testTimeoutWithNothingHeardDropsTheSocket() {
        var core = VaultSessionCore()
        let a = core.submit(key: "a", kind: .req, frame: "A").token
        _ = core.connected()                       // no challenge: an open vault
        let out = core.timedOut(key: "a", token: a)
        guard case .disconnect? = out.first else { return XCTFail("dead socket kept") }
        guard case .connect? = core.submit(key: "b", kind: .req, frame: "B").effects.first else { return XCTFail("no new socket") }
    }

    /// A slow vault (it answered something since the request went) keeps
    /// its socket: only that request ends.
    func testTimeoutOnASlowVaultKeepsTheSocket() {
        var core = VaultSessionCore()
        let a = core.submit(key: "a", kind: .req, frame: "A").token
        _ = core.submit(key: "b", kind: .req, frame: "B")
        _ = core.connected()
        _ = core.received(type: "EVENT", ["EVENT", "a", ["id": "e1"]])
        let out = core.timedOut(key: "a", token: a)
        XCTAssertFalse(out.contains { if case .disconnect = $0 { return true } else { return false } })
        XCTAssertFalse(core.isIdle, "b still waits")
        XCTAssertEqual(core.link, .up)
    }

    /// The same event published again while the first is out ends the first
    /// as failed, without calling the socket dead: other requests on it go on
    /// (Tron, PR 1739: it used to run the dead-socket check and fail them all).
    func testSameKeyAgainEndsOnlyTheFirst() {
        var core = VaultSessionCore()
        _ = core.submit(key: "q", kind: .req, frame: "Q")
        _ = core.submit(key: "e", kind: .event, frame: "E")
        _ = core.connected()                       // sent; nothing heard yet
        let again = core.submit(key: "e", kind: .event, frame: "E")
        XCTAssertFalse(again.effects.contains { if case .disconnect = $0 { return true } else { return false } }, "socket called dead")
        guard case .finish("e", .failed)? = again.effects.first else { return XCTFail("first not ended") }
        XCTAssertTrue(again.effects.contains { if case .send("E") = $0 { return true } else { return false } }, "second not sent")
        XCTAssertEqual(core.link, .up)
        guard case .events? = core.received(type: "EOSE", ["EOSE", "q"]).last.map({ if case .finish(_, let o) = $0 { return o } else { return .failed } }) else {
            return XCTFail("q failed with the first e")
        }
    }

    /// The first submission's timer, firing after a retry of the same event,
    /// does nothing: only the retry's own timer can end it.
    func testOldTimerDoesNotEndARetry() {
        var core = VaultSessionCore()
        let first = core.submit(key: "e", kind: .event, frame: "E").token
        _ = core.connected()
        _ = core.received(type: "OK", ["OK", "e", false, "error: nope"])  // failed; the user retries
        let retry = core.submit(key: "e", kind: .event, frame: "E").token
        XCTAssertNotEqual(first, retry)
        XCTAssertTrue(core.timedOut(key: "e", token: first).isEmpty, "old timer ended the retry")
        XCTAssertFalse(core.isIdle)
        XCTAssertFalse(core.timedOut(key: "e", token: retry).isEmpty)
    }

    /// A second holding a full page or more of versions doesn't end paging:
    /// a full page with nothing new steps to the second before it (Tron,
    /// PR 1739; same class as Go's drainSecond).
    func testFullPageOfOneSecondStepsPastIt() {
        let page = (0..<3).map { (id: "s\($0)", createdAt: 500) }
        XCTAssertEqual(VaultPaging.nextUntil(page: page, known: [], limit: 3), 500)
        XCTAssertEqual(VaultPaging.nextUntil(page: page, known: Set(page.map(\.id)), limit: 3), 499)
        XCTAssertNil(VaultPaging.nextUntil(page: Array(page.prefix(2)), known: [], limit: 3))
    }
}

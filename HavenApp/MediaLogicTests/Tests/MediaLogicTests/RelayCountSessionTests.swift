import XCTest
@testable import MediaLogic

final class RelayCountSessionTests: XCTestCase {
    private let prefix = "vc-abc123-"

    private func session(needsAuth: Bool, keys: Set<String> = ["total", "k1"]) -> RelayCountSession {
        RelayCountSession(keys: keys, prefix: prefix, needsAuth: needsAuth)
    }

    private func count(_ key: String, _ n: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["COUNT", prefix + key, ["count": n]])
        return String(data: data, encoding: .utf8)!
    }

    func testOnlyPrivateAndChatNeedAuth() {
        let base = URL(string: "wss://127.0.0.1:3355")!
        XCTAssertFalse(RelayCountSession.needsAuth(base))
        XCTAssertFalse(RelayCountSession.needsAuth(base.appendingPathComponent("inbox")))
        XCTAssertTrue(RelayCountSession.needsAuth(base.appendingPathComponent("private")))
        XCTAssertTrue(RelayCountSession.needsAuth(base.appendingPathComponent("chat")))
    }

    func testWatchOnlyCountsOnlyThePublicRoutes() {
        let base = URL(string: "wss://127.0.0.1:3355")!
        let all = ["", "inbox", "private", "chat"].map { $0.isEmpty ? base : base.appendingPathComponent($0) }
        XCTAssertEqual(RelayCountSession.countable(all, canSignAsOwner: true), all)
        XCTAssertEqual(RelayCountSession.countable(all, canSignAsOwner: false), Array(all.prefix(2)))
    }

    func testOpenRouteCountsOnConnectAndFinishes() {
        var s = session(needsAuth: false)
        XCTAssertEqual(s.connected(), .sendCounts)
        XCTAssertEqual(s.connected(), .wait, "counts go out once")
        XCTAssertEqual(s.receive(count("total", 12)), .wait)
        XCTAssertEqual(s.receive(count("k1", 5)), .finished(["total": 12, "k1": 5]))
    }

    func testAuthRouteWaitsForOKBeforeCounting() {
        var s = session(needsAuth: true)
        XCTAssertEqual(s.connected(), .wait, "no COUNT before AUTH")
        XCTAssertEqual(s.receive(#"["AUTH","chal-1"]"#), .signAuth(challenge: "chal-1"))
        XCTAssertEqual(s.receive(#"["AUTH","chal-2"]"#), .wait, "one AUTH per socket")
        s.authSent(id: "ev1")
        XCTAssertEqual(s.receive(#"["OK","other",true,""]"#), .wait, "someone else's OK")
        XCTAssertEqual(s.receive(#"["OK","ev1",true,""]"#), .sendCounts)
        XCTAssertEqual(s.receive(count("total", 3)), .wait)
        XCTAssertEqual(s.receive(count("k1", 0)), .finished(["total": 3, "k1": 0]))
    }

    func testChallengeBeforeConnectedIsKept() {
        // The challenge can land before the connected state is published.
        var s = session(needsAuth: true)
        XCTAssertEqual(s.receive(#"["AUTH","early"]"#), .signAuth(challenge: "early"))
        XCTAssertEqual(s.connected(), .wait)
    }

    func testRefusedAuthFails() {
        var s = session(needsAuth: true)
        _ = s.receive(#"["AUTH","c"]"#)
        s.authSent(id: "ev1")
        XCTAssertEqual(s.receive(#"["OK","ev1",false,"error: failed to authenticate"]"#), .failed)
        XCTAssertEqual(s.receive(count("total", 0)), .wait, "nothing after failing")
    }

    func testUnsignableAuthFails() {
        var s = session(needsAuth: true)
        _ = s.receive(#"["AUTH","c"]"#)
        XCTAssertEqual(s.authUnavailable(), .failed)
    }

    /// The relay refuses a COUNT with a NOTICE and then still replies 0;
    /// that 0 must never be taken as the answer.
    func testNoticeThenZeroIsFailureNotZero() {
        var s = session(needsAuth: false, keys: ["total"])
        _ = s.connected()
        XCTAssertEqual(s.receive(#"["NOTICE","auth-required: all requests must be authenticated"]"#), .failed)
        XCTAssertEqual(s.receive(count("total", 0)), .wait)
    }

    func testClosedForOurSubscriptionFails() {
        var s = session(needsAuth: false)
        _ = s.connected()
        XCTAssertEqual(s.receive(#"["CLOSED","someone-else","x"]"#), .wait)
        XCTAssertEqual(s.receive(#"["CLOSED","vc-abc123-k1","restricted"]"#), .failed)
    }

    func testCountWithoutANumberFails() {
        var s = session(needsAuth: false)
        _ = s.connected()
        XCTAssertEqual(s.receive(#"["COUNT","vc-abc123-k1",{}]"#), .failed)
        var t = session(needsAuth: false)
        _ = t.connected()
        XCTAssertEqual(t.receive(count("k1", -1)), .failed)
    }

    func testCountNumberShapes() {
        var s = session(needsAuth: false, keys: ["a", "b", "c"])
        _ = s.connected()
        XCTAssertEqual(s.receive(count("a", 4)), .wait)
        XCTAssertEqual(s.receive(count("b", 7.0)), .wait)
        XCTAssertEqual(s.receive(count("c", "9")), .finished(["a": 4, "b": 7, "c": 9]))
    }

    func testIgnoresOtherSubscriptionsAndJunk() {
        var s = session(needsAuth: false, keys: ["total"])
        _ = s.connected()
        XCTAssertEqual(s.receive("not json"), .wait)
        XCTAssertEqual(s.receive(#"["COUNT","vc-other-total",{"count":99}]"#), .wait)
        XCTAssertEqual(s.receive(count("unknown", 1)), .wait)
        XCTAssertEqual(s.receive(#"["EOSE","x"]"#), .wait)
        XCTAssertEqual(s.receive(count("total", 2)), .finished(["total": 2]))
    }
}

import XCTest
@testable import MediaLogic

/// The desktop Vault status read (haven-go/vault_status.go) and the words
/// the Mac card and the phones show for it.
final class VaultStatusTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)

    private func status(_ json: String) throws -> VaultStatus {
        try XCTUnwrap(VaultStatus.decode(Data(json.utf8)))
    }

    private func buckets(_ at: [Int: Int]) -> String {
        "[" + (0...100).map { String(at[$0] ?? 0) }.joined(separator: ",") + "]"
    }

    func testARunningPassSaysItsRingAndLists() throws {
        let s = try status("""
        {"version":1,"at":1000,"state":"running","accounts":[{"account":"\(me)","running":true,"ring":3,"ringDone":412,
        "ringTotal":1980,"listsRead":37,"finishedAt":0,"distantAtBar":0,"handoffs":[]}]}
        """)
        XCTAssertEqual(VaultStatusText.headline(s), "Ranking your web")
        let a = try XCTUnwrap(s.account(me))
        XCTAssertEqual(VaultStatusText.progress(a), "Ring 3 · 412 of 1,980 lists · 37 read this run")
        XCTAssertEqual(VaultStatusText.finished(a, now: Date(timeIntervalSince1970: 1000)), "No ranking yet")
        XCTAssertNil(VaultStatusText.pausedHint(s))
    }

    func testPausedSaysWhyAndKeepsItsPlace() throws {
        let s = try status("""
        {"version":1,"at":1000,"state":"paused","pausedWhy":"app","accounts":[{"account":"\(me)","running":false,"ring":2,
        "ringDone":50,"cut":true,"finishedAt":0,"distantAtBar":0,"handoffs":[]}]}
        """)
        XCTAssertEqual(VaultStatusText.headline(s), "Paused while the window is open")
        XCTAssertNotNil(VaultStatusText.pausedHint(s))
        XCTAssertEqual(VaultStatusText.progress(try XCTUnwrap(s.accounts.first)), "Ring 2 · 50 lists read · waiting to go on")
        var busy = s
        busy.pausedWhy = "busy"
        XCTAssertEqual(VaultStatusText.headline(busy), "Paused while an import or copy runs")
        XCTAssertNil(VaultStatusText.pausedHint(busy))
    }

    func testAFinishedPassCountsDistantConnectionsAtTheBar() throws {
        let s = try status("""
        {"version":1,"at":10000,"state":"idle","accounts":[{"account":"\(me)","running":false,"finishedAt":2800,
        "result":{"builtAt":2800,"people":78855,"maxHop":5,"rings":[1,2],"distantByShown":\(buckets([54: 5, 55: 3, 80: 2])),"viewBar":55},
        "distantAtBar":5,"distantFetchAt":9280,"distantFetchPeople":500,"distantFetchNew":34,
        "handoffs":[{"device":"\(String(repeating: "b", count: 64))","role":"phone","tookAt":6400,"builtAt":2800,"checkedAt":9900},
        {"device":"\(String(repeating: "c", count: 64))","checkedAt":9900}]}]}
        """)
        let now = Date(timeIntervalSince1970: 10000)
        let a = try XCTUnwrap(s.account("unknown"))
        XCTAssertEqual(VaultStatusText.headline(s), "Idle")
        XCTAssertNil(VaultStatusText.progress(a))
        XCTAssertEqual(VaultStatusText.finished(a, now: now), "Finished 2 h ago · 78,855 people ranked")
        XCTAssertEqual(VaultStatusText.distant(a, bar: nil), "5 distant connections at your bar (55)")
        XCTAssertEqual(VaultStatusText.distant(a, bar: 54), "10 distant connections at your bar (54)")
        XCTAssertEqual(VaultStatusText.distant(a, bar: 81), "0 distant connections at your bar (81)")
        XCTAssertEqual(VaultStatusText.distantFetch(a, now: now), "Distant posts fetched 12 min ago · 34 new from 500 people")
        XCTAssertEqual(VaultStatusText.handoff(a.handoffs[0], now: now), "Took it 1 h ago")
        XCTAssertEqual(VaultStatusText.handoff(a.handoffs[1], now: now), "Hasn't taken the ranking yet")
    }

    func testOffAndAgo() throws {
        let s = try status(#"{"version":1,"at":1,"state":"off","accounts":[]}"#)
        XCTAssertEqual(VaultStatusText.headline(s), "Trust ranking is off here")
        XCTAssertNil(s.account(me))
        let now = Date(timeIntervalSince1970: 200_000)
        XCTAssertEqual(VaultStatusText.ago(199_990, now: now), "just now")
        XCTAssertEqual(VaultStatusText.ago(200_000 - 86_400, now: now), "1 day ago")
        XCTAssertEqual(VaultStatusText.ago(300_000, now: now), "just now", "a clock ahead is never negative")
        XCTAssertNil(VaultStatus.decode(Data("not json".utf8)))
    }
}

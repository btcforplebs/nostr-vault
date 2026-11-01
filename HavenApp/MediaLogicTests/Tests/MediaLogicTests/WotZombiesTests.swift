import XCTest
@testable import MediaLogic

/// Zombies in your web: decoding the vault's answer, keeping the list to
/// people still followed, and the words. Read-only: nothing here unfollows.
final class WotZombiesTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private func pk(_ c: Character) -> String { String(repeating: c, count: 64) }

    /// The shape haven-go's ZombieState marshals to, extra fields included.
    private var json: String {
        """
        {"checking":false,"report":{"owner":"\(me)","follows":5,"fresh":1,"rotting":1,"ancient":2,
        "zombies":[
          {"pubkey":"\(pk("1"))","last_seen":0,"kind":0,"days":365,"bucket":"ancient"},
          {"pubkey":"\(pk("2"))","last_seen":1700000000,"kind":3,"floor":true,"days":400,"bucket":"ancient"},
          {"pubkey":"\(pk("3"))","last_seen":1760000000,"kind":1,"days":200,"bucket":"rotting"},
          {"pubkey":"\(pk("4"))","last_seen":1780000000,"kind":30443,"days":95,"bucket":"fresh"}],
        "checked_at":1793534400,"took_ms":40000}}
        """
    }

    func testDecodesTheVaultsReport() throws {
        let state = try XCTUnwrap(WotZombies.State.decode(json))
        XCTAssertFalse(state.checking)
        let report = try XCTUnwrap(state.report)
        XCTAssertEqual(report.owner, me)
        XCTAssertEqual(report.follows, 5)
        XCTAssertEqual(report.zombies.map(\.bucket), [.ancient, .ancient, .rotting, .fresh])
        XCTAssertEqual(report.count(.ancient), 2)
        XCTAssertEqual(report.count(.rotting), 1)
        XCTAssertEqual(report.count(.fresh), 1)
        XCTAssertEqual(report.zombies[1].lastSeen, 1_700_000_000)
    }

    func testDecodesCheckingAndErrors() throws {
        let checking = try XCTUnwrap(WotZombies.State.decode(#"{"checking":true}"#))
        XCTAssertTrue(checking.checking)
        XCTAssertNil(checking.report)
        let error = try XCTUnwrap(WotZombies.State.decode(#"{"error":"relay not running"}"#))
        XCTAssertEqual(error.error, "relay not running")
        XCTAssertFalse(error.checking)
        XCTAssertNil(WotZombies.State.decode("not json"))
    }

    /// Someone unfollowed since the check (in Plebs vs. Zombies or anywhere) leaves the list and the
    /// counts at once, without waiting for the vault's next check.
    func testKeepingOnlyPeopleStillFollowed() throws {
        let report = try XCTUnwrap(WotZombies.State.decode(json)?.report)
        let kept = report.keeping(following: [pk("2"), pk("4"), pk("9")])
        XCTAssertEqual(kept.zombies.map(\.pubkey), [pk("2"), pk("4")])
        XCTAssertEqual(kept.follows, 3)
        XCTAssertEqual(kept.count(.ancient), 1)
        XCTAssertEqual(kept.count(.rotting), 0)
    }

    func testWords() {
        XCTAssertEqual(WotZombies.headline(quiet: 65, follows: 1053), "65 of your 1,053 follows have been quiet 90+ days")
        XCTAssertEqual(WotZombies.headline(quiet: 1, follows: 10), "1 of your 10 follows has been quiet 90+ days")
        XCTAssertEqual(WotZombies.headline(quiet: 0, follows: 10), "None of your 10 follows have been quiet 90+ days")
        XCTAssertEqual(WotZombies.listHeader(quiet: 65), "65 quiet 90+ days, longest first")
        XCTAssertEqual(WotZombies.plebsVsZombiesURL.absoluteString, "https://plebsvszombies.cc")
        XCTAssertEqual(WotZombies.Bucket.allCases.map(\.daysText), ["90+ days", "180+ days", "365+ days"])
    }

    func testLastSeenText() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_793_534_400)
        func ago(_ c: DateComponents) -> Int64 { Int64(cal.date(byAdding: c, to: now)!.timeIntervalSince1970) }
        XCTAssertEqual(WotZombies.lastSeenText(ago(DateComponents(year: -2, month: -6)), now: now), "Last seen 2 yr 6 mo ago")
        XCTAssertEqual(WotZombies.lastSeenText(ago(DateComponents(year: -1)), now: now), "Last seen 1 yr ago")
        XCTAssertEqual(WotZombies.lastSeenText(ago(DateComponents(month: -11)), now: now), "Last seen 11 months ago")
        XCTAssertEqual(WotZombies.lastSeenText(ago(DateComponents(month: -1)), now: now), "Last seen 1 month ago")
        XCTAssertEqual(WotZombies.lastSeenText(0, now: now), "Nothing signed by them found")
    }
}

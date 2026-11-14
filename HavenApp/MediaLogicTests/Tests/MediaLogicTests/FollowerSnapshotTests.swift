import XCTest
@testable import MediaLogic

/// The Followers page split by web of trust (Logen 2026-11-14): your web by
/// default, the rest behind ··· "Outside your web", spam on neither; the red
/// dot, follow lines and dashboard +N count news from your web only.
final class FollowerSnapshotTests: XCTestCase {
    private func snapshot(_ json: String) throws -> FollowerSnapshot {
        try JSONDecoder().decode(FollowerSnapshot.self, from: Data(json.utf8))
    }

    private func entry(_ pk: String, tier: String = "other", following: Bool = true, existing: Bool = false,
                       at: Int64, follows: Int = 1) -> String {
        #"{"pubkey":"\#(pk)","tier":"\#(tier)","following":\#(following),"existing":\#(existing),"followed_at":\#(at),"follows":\#(follows),"list_at":\#(at)}"#
    }

    private func ledger() throws -> FollowerSnapshot {
        try snapshot(#"{"counts":{"trusted":2,"others":3,"spam":1,"unfollowed":1},"followers":["#
            + [entry("friend", tier: "trusted", at: 500),
               entry("stranger", at: 400),
               entry("oldFriend", tier: "trusted", existing: true, at: 100),
               entry("oldStranger", existing: true, at: 90),
               entry("bot", tier: "spam", at: 450),
               entry("leftFriend", following: false, at: 300)].joined(separator: ",") + "]}")
    }

    private let outside: (String) -> Bool = { $0.hasPrefix("stranger") || $0 == "oldStranger" || $0 == "bot" }

    func testDefaultListIsYourWebNewestFirst() throws {
        XCTAssertEqual(try ledger().entries(for: .inWeb, isOutside: outside).map(\.pubkey), ["friend", "oldFriend"])
    }

    func testOutsideListIsTheRestWithoutSpam() throws {
        XCTAssertEqual(try ledger().entries(for: .outside, isOutside: outside).map(\.pubkey), ["stranger", "oldStranger"])
    }

    /// The two lists cover every current follower once.
    func testListsSplitWithoutGapOrOverlap() throws {
        let l = try ledger()
        let both = l.entries(for: .inWeb, isOutside: outside) + l.entries(for: .outside, isOutside: outside)
        XCTAssertEqual(Set(both.map(\.pubkey)), Set(l.current.map(\.pubkey)))
        XCTAssertEqual(both.count, l.current.count)
    }

    /// No graph yet: everyone the rule calls outside waits behind ···.
    func testFailsClosedWithNoGraph() throws {
        XCTAssertTrue(try ledger().entries(for: .inWeb, isOutside: { _ in true }).isEmpty)
    }

    /// The dot, follow lines and +N: news from your web only.
    func testNewsCountsOnlyYourWeb() throws {
        XCTAssertEqual(try ledger().news(isOutside: outside).map(\.pubkey), ["friend"])
        XCTAssertEqual(try ledger().news(isOutside: { _ in false }).map(\.pubkey), ["friend", "stranger"])
    }
}

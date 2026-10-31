import XCTest
@testable import MediaLogic

final class AccountUnreadTests: XCTestCase {
    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)

    private func marker(_ type: String, id: String, to recipient: String, preview: String = "hi") -> String {
        "type=\(type)|kind=1|author=\(String(repeating: "c", count: 64))|id=\(id)|recipient=\(recipient)|preview=\(preview)"
    }

    func testCountsPerRecipient() {
        var u = AccountUnread()
        u.record(marker("reply", id: "1", to: alice))
        u.record(marker("zap", id: "2", to: alice))
        u.record(marker("mention", id: "3", to: bob))
        XCTAssertEqual(u.count(for: alice), 2)
        XCTAssertEqual(u.count(for: bob), 1)
    }

    func testSameEventCountsOnce() {
        var u = AccountUnread()
        XCTAssertTrue(u.record(marker("reaction", id: "1", to: alice)))
        XCTAssertFalse(u.record(marker("reaction", id: "1", to: alice)))
        XCTAssertEqual(u.count(for: alice), 1)
    }

    func testDmsSummaryAndUnnamedAccountDoNotCount() {
        var u = AccountUnread()
        u.record(marker("dm", id: "1", to: alice))
        u.record(marker("giftwrap", id: "2", to: alice))
        u.record("type=summary|kind=0|author=|id=|recipient=|preview=4 more new items while you were away")
        u.record(marker("reply", id: "3", to: ""))
        u.record(marker("reply", id: "4", to: "npub1notahex"))
        XCTAssertEqual(u.ids, [:])
    }

    func testPreviewCannotForgeFields() {
        let forged = "type=reply|kind=1|author=x|id=1|recipient=\(alice)|preview=a|recipient=\(bob)|id=9"
        XCTAssertEqual(AccountUnread.parse(forged)?.recipient, alice)
        XCTAssertEqual(AccountUnread.parse(forged)?.id, "1")
    }

    func testMarkSeenEmptiesOnlyThatAccount() {
        var u = AccountUnread()
        u.record(marker("reply", id: "1", to: alice))
        u.record(marker("reply", id: "2", to: bob))
        XCTAssertTrue(u.markSeen(alice.uppercased()))
        XCTAssertEqual(u.count(for: alice), 0)
        XCTAssertEqual(u.count(for: bob), 1)
        XCTAssertFalse(u.markSeen(alice))
    }

    func testFollowersCountOneEach() {
        var u = AccountUnread()
        u.record("type=follow|kind=3|author=x|id=f1|recipient=\(alice)|preview=")
        u.record("type=follow|kind=3|author=y|id=f2|recipient=\(alice)|preview=")
        XCTAssertEqual(u.count(for: alice), 2)
    }

    func testCapKeepsNewest() {
        var u = AccountUnread()
        for i in 0..<(AccountUnread.cap + 5) { u.record(marker("reply", id: "\(i)", to: alice)) }
        XCTAssertEqual(u.count(for: alice), AccountUnread.cap)
        XCTAssertEqual(u.ids[alice]?.first, "5")
        XCTAssertFalse(u.record(marker("reply", id: "\(AccountUnread.cap + 4)", to: alice)))
    }

    func testBadgeText() {
        XCTAssertNil(AccountUnread.badge(0))
        XCTAssertEqual(AccountUnread.badge(7), "7")
        XCTAssertEqual(AccountUnread.badge(99), "99")
        XCTAssertEqual(AccountUnread.badge(100), "99+")
    }

    func testOtherAccountDot() {
        var u = AccountUnread()
        let both = [alice, bob]
        XCTAssertFalse(u.othersHaveUnread(accounts: both, active: alice))
        // News for the active account alone: its Vault tab has the dot, not the avatar.
        u.record(marker("reply", id: "1", to: alice))
        XCTAssertFalse(u.othersHaveUnread(accounts: both, active: alice))
        u.record(marker("zap", id: "2", to: bob))
        XCTAssertTrue(u.othersHaveUnread(accounts: both, active: alice))
        XCTAssertTrue(u.othersHaveUnread(accounts: both, active: alice.uppercased()))
        // Switching to bob: now alice is the other account with news.
        XCTAssertTrue(u.othersHaveUnread(accounts: both, active: bob))
        u.markSeen(bob)
        XCTAssertFalse(u.othersHaveUnread(accounts: both, active: alice))
    }

    func testRemovedAccountDoesNotHoldTheDot() {
        var u = AccountUnread()
        u.record(marker("reply", id: "1", to: bob))
        XCTAssertFalse(u.othersHaveUnread(accounts: [alice], active: alice))
    }
}

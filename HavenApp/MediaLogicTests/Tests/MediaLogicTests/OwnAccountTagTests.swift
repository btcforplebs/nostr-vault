import XCTest
@testable import MediaLogic

/// "Notify me when my own accounts tag each other" (off by default): one of
/// your accounts tagging another makes no alert, no Vault count and no red dot.
final class OwnAccountTagTests: XCTestCase {
    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)
    private let carol = String(repeating: "c", count: 64)
    private var mine: Set<String> { [alice, bob] }

    private func hides(_ author: String, _ recipient: String, notify: Bool = false) -> Bool {
        NotificationPolicy.hidesOwnAccountTag(author: author, recipient: recipient, accounts: mine, notify: notify)
    }

    func testOneOfMyAccountsTaggingAnotherIsHiddenWhileOff() {
        XCTAssertTrue(hides(alice, bob))
        XCTAssertTrue(hides(bob, alice))
    }

    func testTurningItOnShowsIt() {
        XCTAssertFalse(hides(alice, bob, notify: true))
    }

    func testSomeoneElseIsNeverHidden() {
        XCTAssertFalse(hides(carol, bob))
        XCTAssertFalse(hides("", bob))
    }

    func testAnAccountTaggingItselfIsLeftToTheRelay() {
        XCTAssertFalse(hides(alice, alice))
    }

    func testARecipientThatIsNotMineIsNotHidden() {
        XCTAssertFalse(hides(alice, carol))
        XCTAssertFalse(hides(alice, ""))
    }

    func testCaseDoesNotMatter() {
        XCTAssertTrue(NotificationPolicy.hidesOwnAccountTag(
            author: alice.uppercased(), recipient: bob, accounts: [alice, bob.uppercased()], notify: false))
    }

    // MARK: Vault count

    private func marker(_ type: String, kind: Int = 1, id: String, from author: String, to recipient: String) -> String {
        "type=\(type)|kind=\(kind)|author=\(author)|id=\(id)|recipient=\(recipient)|preview=hi"
    }

    private var rules: AccountUnread.ListRules {
        var r = AccountUnread.ListRules()
        let accounts = mine
        r.isOwnAccountTag = { recipient, author in
            NotificationPolicy.hidesOwnAccountTag(author: author, recipient: recipient, accounts: accounts, notify: false)
        }
        return r
    }

    func testOwnAccountTagDoesNotCount() {
        var u = AccountUnread()
        XCTAssertFalse(u.record(marker("mention", id: "1", from: alice, to: bob), rules: rules))
        XCTAssertTrue(u.record(marker("mention", id: "2", from: carol, to: bob), rules: rules))
        XCTAssertEqual(u.count(for: bob), 1)
    }

    // MARK: Vault tab red dot

    func testKindOnlyFromMyOwnAccountsIsLeftOut() {
        let kinds = AccountUnread.ownAccountOnlyKinds(
            markers: [marker("mention", id: "1", from: alice, to: bob),
                      marker("reaction", kind: 7, id: "2", from: alice, to: bob)],
            isOwnAccountTag: rules.isOwnAccountTag)
        XCTAssertEqual(kinds, [1, 7])
    }

    func testKindAlsoFromSomeoneElseStays() {
        let kinds = AccountUnread.ownAccountOnlyKinds(
            markers: [marker("mention", id: "1", from: alice, to: bob),
                      marker("reply", id: "2", from: carol, to: bob)],
            isOwnAccountTag: rules.isOwnAccountTag)
        XCTAssertEqual(kinds, [])
    }

    func testNothingLeftOutWhenTheSwitchIsOn() {
        let accounts = mine
        let kinds = AccountUnread.ownAccountOnlyKinds(
            markers: [marker("mention", id: "1", from: alice, to: bob)],
            isOwnAccountTag: { r, a in
                NotificationPolicy.hidesOwnAccountTag(author: a, recipient: r, accounts: accounts, notify: true)
            })
        XCTAssertEqual(kinds, [])
    }
}

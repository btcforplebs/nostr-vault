import XCTest
@testable import MediaLogic

/// B9: a chat keeps what you typed when you leave it, per account and person.
final class DMDraftsTests: XCTestCase {
    func testDraftsArePerAccountAndPerson() {
        let drafts = DMDrafts()
        drafts.set("hello", account: "AA", counterparty: "bb")
        XCTAssertEqual(drafts.text(account: "aa", counterparty: "BB"), "hello", "case does not matter")
        XCTAssertNil(drafts.text(account: "aa", counterparty: "cc"))
        XCTAssertNil(drafts.text(account: "dd", counterparty: "bb"))
    }

    func testBlankRemovesTheDraft() {
        let drafts = DMDrafts()
        drafts.set("hi", account: "aa", counterparty: "bb")
        drafts.set("  \n", account: "aa", counterparty: "bb")
        XCTAssertNil(drafts.text(account: "aa", counterparty: "bb"))
    }

    func testAccountSwitchKeepsOnlyTheNewAccounts() {
        let drafts = DMDrafts()
        drafts.set("old", account: "aa", counterparty: "bb")
        drafts.set("new", account: "cc", counterparty: "bb")
        drafts.keepOnly(account: "CC")
        XCTAssertNil(drafts.text(account: "aa", counterparty: "bb"))
        XCTAssertEqual(drafts.text(account: "cc", counterparty: "bb"), "new")
    }
}

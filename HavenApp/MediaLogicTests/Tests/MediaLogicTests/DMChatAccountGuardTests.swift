import XCTest
@testable import MediaLogic

/// A5 in RESEARCH/NV_MESSAGES_UX_CHECK_2026_11_18.md: a chat left open across
/// an account switch must close, and Send must never go out as the new account.
final class DMChatAccountGuardTests: XCTestCase {
    let alice = String(repeating: "a", count: 64)
    let bob = String(repeating: "b", count: 64)

    func testSameAccountMaySend() {
        XCTAssertTrue(DMChatAccountGuard.maySend(openedAs: alice, active: alice))
        XCTAssertFalse(DMChatAccountGuard.mustClose(openedAs: alice, active: alice))
    }

    func testSwitchedAccountRefusesSendAndCloses() {
        XCTAssertFalse(DMChatAccountGuard.maySend(openedAs: alice, active: bob))
        XCTAssertTrue(DMChatAccountGuard.mustClose(openedAs: alice, active: bob))
    }

    func testSignedOutRefusesSendAndCloses() {
        XCTAssertFalse(DMChatAccountGuard.maySend(openedAs: alice, active: ""))
        XCTAssertTrue(DMChatAccountGuard.mustClose(openedAs: alice, active: ""))
    }

    func testUnknownOpeningAccountRefusesSendButDoesNotClose() {
        // Not yet recorded (before the chat appeared): nothing to compare.
        XCTAssertFalse(DMChatAccountGuard.maySend(openedAs: nil, active: alice))
        XCTAssertFalse(DMChatAccountGuard.maySend(openedAs: "", active: alice))
        XCTAssertFalse(DMChatAccountGuard.mustClose(openedAs: nil, active: alice))
    }
}

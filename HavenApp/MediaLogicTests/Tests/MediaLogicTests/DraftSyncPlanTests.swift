import XCTest
@testable import MediaLogic

/// Mac bug hunt 2026-11-05 #1 and #4: queued drafts and new notes went out as
/// the account active at the time, not the one that wrote them.
final class DraftSyncPlanTests: XCTestCase {
    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)

    /// A's queued save/delete waits while B is active, and goes once A is.
    func testQueuedItemsWaitForTheirAccount() {
        let saves = [PendingDraftDelete(id: "1", pubkey: a), PendingDraftDelete(id: "2", pubkey: b),
                     PendingDraftDelete(id: "3", pubkey: nil)]
        let whileB = DraftSyncPlan.split(saves, author: \.pubkey, active: b)
        XCTAssertEqual(whileB.now.map(\.id), ["2", "3"])
        XCTAssertEqual(whileB.later.map(\.id), ["1"])
        let backToA = DraftSyncPlan.split(whileB.later, author: \.pubkey, active: a.uppercased())
        XCTAssertEqual(backToA.now.map(\.id), ["1"])
        XCTAssertTrue(backToA.later.isEmpty)
    }

    func testNothingAuthoredGoesWithNoActiveAccount() {
        XCTAssertFalse(DraftSyncPlan.isDue(author: a, active: ""))
        XCTAssertTrue(DraftSyncPlan.isDue(author: nil, active: ""))
        XCTAssertTrue(DraftSyncPlan.isDue(author: "", active: b))
    }

    /// #4: a new note (no postAs) is locked to the account active when the
    /// composer opened, so a switch to B before Post switches back to A.
    func testNewNoteIsLockedToTheAccountItOpenedAs() {
        let owner = "npub1owner", accA = "npub1aaa", accB = "npub1bbb"
        let opened = PostingAccount.composerAccount(postAs: nil, active: accA, owner: owner)
        XCTAssertEqual(opened, accA)
        XCTAssertEqual(PostingAccount.switchTarget(postAs: opened, active: accB, owner: owner), accA)
        XCTAssertNil(PostingAccount.switchTarget(postAs: opened, active: accA, owner: owner))
        XCTAssertEqual(PostingAccount.composerAccount(postAs: nil, active: "", owner: owner), owner)
        XCTAssertEqual(PostingAccount.composerAccount(postAs: accB, active: accA, owner: owner), accB)
    }
}

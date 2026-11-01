import XCTest
@testable import MediaLogic

final class PostingAccountTests: XCTestCase {
    let owner = "npub1owner"
    let alt = "npub1alt"
    let ownerHex = String(repeating: "a", count: 64)
    let altHex = String(repeating: "b", count: 64)

    func testEmptyActiveResolvesToOwner() {
        XCTAssertEqual(PostingAccount.resolve(active: "", owner: owner), owner)
        XCTAssertEqual(PostingAccount.resolve(active: "  ", owner: owner), owner)
        XCTAssertEqual(PostingAccount.resolve(active: alt, owner: owner), alt)
    }

    func testSameAccountAndKeyIsAllowed() {
        XCTAssertTrue(PostingAccount.signedAsLocked(lockedNpub: alt, lockedHex: altHex, activeNow: alt, owner: owner, eventPubkey: altHex))
        // Owner stored as "" (the switcher's form) still matches an owner lock.
        XCTAssertTrue(PostingAccount.signedAsLocked(lockedNpub: owner, lockedHex: ownerHex, activeNow: "", owner: owner, eventPubkey: ownerHex))
    }

    func testSwitchDuringUploadIsRefused() {
        // Locked as owner; account switched to alt; note signed by alt.
        XCTAssertFalse(PostingAccount.signedAsLocked(lockedNpub: owner, lockedHex: ownerHex, activeNow: alt, owner: owner, eventPubkey: altHex))
        // Switched away and back during the sign is fine only if the key matches.
        XCTAssertFalse(PostingAccount.signedAsLocked(lockedNpub: owner, lockedHex: ownerHex, activeNow: "", owner: owner, eventPubkey: altHex))
        // Signed as the locked account, but the active account changed: refused.
        XCTAssertFalse(PostingAccount.signedAsLocked(lockedNpub: owner, lockedHex: ownerHex, activeNow: alt, owner: owner, eventPubkey: ownerHex))
    }

    func testMissingLockedKeyIsRefused() {
        XCTAssertFalse(PostingAccount.signedAsLocked(lockedNpub: owner, lockedHex: "", activeNow: "", owner: owner, eventPubkey: ""))
    }

    /// A reply carries the account its note was opened as; posting it needs
    /// that account active, whatever was switched to in between.
    func testSwitchTargetForAReplyFromAnotherAccount() {
        // Opened as alt, owner active now (a notification tap): switch to alt.
        XCTAssertEqual(PostingAccount.switchTarget(postAs: alt, active: "", owner: owner), alt)
        XCTAssertEqual(PostingAccount.switchTarget(postAs: alt, active: owner, owner: owner), alt)
        // Opened as owner, alt active now: back to the owner.
        XCTAssertEqual(PostingAccount.switchTarget(postAs: owner, active: alt, owner: owner), owner)
        // Already the right account, in either stored form of the owner.
        XCTAssertNil(PostingAccount.switchTarget(postAs: alt, active: alt, owner: owner))
        XCTAssertNil(PostingAccount.switchTarget(postAs: owner, active: "", owner: owner))
        XCTAssertNil(PostingAccount.switchTarget(postAs: " \(alt) ", active: alt, owner: owner))
        // No account asked for: post as whoever is active.
        XCTAssertNil(PostingAccount.switchTarget(postAs: nil, active: alt, owner: owner))
        XCTAssertNil(PostingAccount.switchTarget(postAs: "  ", active: alt, owner: owner))
    }
}

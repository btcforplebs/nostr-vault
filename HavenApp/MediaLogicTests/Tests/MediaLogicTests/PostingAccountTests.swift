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
}

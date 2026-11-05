import XCTest
@testable import MediaLogic

/// Bug hunt 2026-11-05 #2/#3: a key from an earlier way through setup stayed
/// saved next to another npub.
final class SetupOwnerKeyTests: XCTestCase {
    private enum Way { case newToNostr, useNostr }

    /// Sim repro: Create an account (key X saved) → Back → I already use
    /// Nostr → npub Y only. X's key must be cleared, not kept next to Y.
    func testAnotherAccountsSavedKeyIsCleared() {
        XCTAssertEqual(SetupOwnerKey.action(typedKey: false, hasPassword: false, signer: false, npubKnown: true, stored: .other), .clear)
        XCTAssertEqual(SetupOwnerKey.action(typedKey: false, hasPassword: false, signer: true, npubKnown: true, stored: .other), .clear)
        // A new key typed but its password not set yet: the old one still goes.
        XCTAssertEqual(SetupOwnerKey.action(typedKey: true, hasPassword: false, signer: false, npubKnown: true, stored: .other), .clear)
    }

    func testOwnKeyIsKeptAndTypedKeyIsWritten() {
        XCTAssertEqual(SetupOwnerKey.action(typedKey: false, hasPassword: false, signer: false, npubKnown: true, stored: .matches), .keep)
        XCTAssertEqual(SetupOwnerKey.action(typedKey: true, hasPassword: true, signer: false, npubKnown: true, stored: .other), .write)
        XCTAssertEqual(SetupOwnerKey.action(typedKey: false, hasPassword: false, signer: false, npubKnown: true, stored: .none), .keep)
    }

    /// Nothing is cleared without an npub to compare with, or when the saved
    /// key can't be read (it can't sign then either).
    func testNoNpubOrUnreadableKeyIsLeftAlone() {
        XCTAssertEqual(SetupOwnerKey.action(typedKey: false, hasPassword: false, signer: false, npubKnown: false, stored: .other), .keep)
        XCTAssertEqual(SetupOwnerKey.action(typedKey: false, hasPassword: false, signer: false, npubKnown: true, stored: .unreadable), .keep)
    }

    /// #3: I use Nostr (pasted nsec) → Back → Create an account must not
    /// offer the pasted key as the new one. The same way again keeps a
    /// generated key the person may have written down.
    func testAnotherWayInResetsTypedKeys() {
        XCTAssertTrue(SetupOwnerKey.resetsTypedKeys(from: Way.useNostr, to: .newToNostr))
        XCTAssertTrue(SetupOwnerKey.resetsTypedKeys(from: Way.newToNostr, to: .useNostr))
        XCTAssertFalse(SetupOwnerKey.resetsTypedKeys(from: Way.newToNostr, to: .newToNostr))
        XCTAssertFalse(SetupOwnerKey.resetsTypedKeys(from: nil, to: Way.newToNostr))
    }
}

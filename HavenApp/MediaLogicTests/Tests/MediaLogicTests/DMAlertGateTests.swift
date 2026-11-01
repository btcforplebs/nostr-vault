import XCTest
@testable import MediaLogic

/// A gift wrap never alerts before it is unlocked, and never for a DM written
/// by any account on this device (Logen 2026-11-01).
final class DMAlertGateTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let second = String(repeating: "b", count: 64)
    private let friend = String(repeating: "c", count: 64)
    private var own: Set<String> { [owner, second] }

    private func alerts(_ sender: String, isFromMe: Bool = false, blocked: Set<String> = [],
                        inInbox: Bool = true, onScreen: Bool = false) -> Bool {
        DMAlertGate.alerts(sender: sender, isFromMe: isFromMe, ownAccounts: own, blocked: blocked,
                           inInbox: inInbox, onScreen: onScreen)
    }

    func testAMessageFromSomeoneElseAlerts() {
        XCTAssertTrue(alerts(friend))
    }

    /// The copy you sent from another device, opened in the active account's inbox.
    func testYourOwnCopyNeverAlerts() {
        XCTAssertFalse(alerts(owner, isFromMe: true))
    }

    /// Sent by a non-active account on this device: the inbox that opened it
    /// doesn't call it "from me", but it is still one of ours.
    func testASelfCopyFromANonActiveAccountNeverAlerts() {
        XCTAssertFalse(alerts(second, isFromMe: false))
        XCTAssertFalse(alerts(second.uppercased(), isFromMe: false))
    }

    func testBlockedRequestsAndTheOpenThreadDontAlert() {
        XCTAssertFalse(alerts(friend, blocked: [friend]))
        XCTAssertFalse(alerts(friend, inInbox: false))
        XCTAssertFalse(alerts(friend, onScreen: true))
        XCTAssertFalse(alerts(""))
    }

    // MARK: - Waiting to be unlocked

    /// A slow signer: the wrap waits, however long, and is decided only when
    /// the inbox opens it. Nothing is decided before.
    func testAWrapWaitsUntilItIsUnlocked() {
        var pending = PendingDMAlerts<String>()
        pending.add("wrap1", "npub-owner")
        XCTAssertEqual(pending.count, 1)
        // Opened later: taken once, then gone.
        XCTAssertEqual(pending.take("wrap1"), "npub-owner")
        XCTAssertNil(pending.take("wrap1"))
        // An event no alert waited for (a backlog wrap) decides nothing.
        XCTAssertNil(pending.take("other"))
    }

    func testAMarkerSeenTwiceWaitsOnce() {
        var pending = PendingDMAlerts<String>()
        pending.add("wrap1", "first")
        pending.add("wrap1", "second")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.take("wrap1"), "first")
    }

    /// Wraps that never open (another account never switched to, bad data)
    /// don't pile up: the oldest go first.
    func testTheQueueDropsTheOldestPastItsLimit() {
        var pending = PendingDMAlerts<Int>(limit: 2)
        pending.add("w1", 1); pending.add("w2", 2); pending.add("w3", 3)
        XCTAssertEqual(pending.count, 2)
        XCTAssertNil(pending.take("w1"))
        XCTAssertEqual(pending.take("w3"), 3)
    }
}

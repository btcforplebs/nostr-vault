import XCTest
@testable import MediaLogic

/// The Add step has a deadline on both sides, so A never says Linked after
/// B has given up waiting for the ack.
final class MeshPairingConfirmWindowTests: XCTestCase {
    /// The latest A ack, sent at the end of A's window after B's latest
    /// hello, still lands inside B's ackWindow with the relay margin.
    func testLatestAckFitsInsideBsWindow() {
        let latestHello = MeshPairingConfirmWindow.helloWindow
        let latestAck = latestHello + MeshPairing.scanWindow + MeshPairingConfirmWindow.relayMargin
        XCTAssertLessThanOrEqual(latestAck, MeshPairing.ackWindow)
    }

    func testATapAfterItsWindowMayNotConfirm() {
        let left = MeshPairingConfirmWindow.secondsLeftForA(helloAt: 1000, now: 1000 + MeshPairing.scanWindow + 1)
        XCTAssertFalse(MeshPairingConfirmWindow.mayConfirm(secondsLeft: left))
    }

    /// Past B's own window A's ack could no longer reach it: refused.
    func testATapPastBsAckWindowMayNotConfirm() {
        let left = MeshPairingConfirmWindow.secondsLeftForA(helloAt: 1000, now: 1000 + MeshPairing.ackWindow)
        XCTAssertFalse(MeshPairingConfirmWindow.mayConfirm(secondsLeft: left))
    }

    func testATapInTimeMayConfirm() {
        let left = MeshPairingConfirmWindow.secondsLeftForA(helloAt: 1000, now: 1010)
        XCTAssertTrue(MeshPairingConfirmWindow.mayConfirm(secondsLeft: left))
    }

    func testBMustSayHelloWithinItsWindow() {
        let late = MeshPairingConfirmWindow.secondsLeftForB(scannedAt: 0, now: MeshPairingConfirmWindow.helloWindow + 1)
        XCTAssertFalse(MeshPairingConfirmWindow.mayConfirm(secondsLeft: late))
        let onTime = MeshPairingConfirmWindow.secondsLeftForB(scannedAt: 0, now: 30)
        XCTAssertTrue(MeshPairingConfirmWindow.mayConfirm(secondsLeft: onTime))
    }
}

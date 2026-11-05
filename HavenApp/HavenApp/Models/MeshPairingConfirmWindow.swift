import Foundation

/// The deadline on each side's "Add" (role confirm) step, so a pairing never
/// ends linked on one side only.
///
/// B waits `MeshPairing.ackWindow` after scanning A. A used to have no clock
/// on its Add step: it could store B and send the ack long after B had given
/// up, and say Linked while B said the code expired. Now:
/// - B says hello within `helloWindow` of the scan (its Add before the hello);
/// - A taps Add within `MeshPairing.scanWindow` of the hello, the same
///   countdown as its scan step.
/// So A's ack leaves while B still takes it, with `relayMargin` for the two
/// relay hops. Past the limit the step fails instead of storing or sending.
enum MeshPairingConfirmWindow {
    /// Seconds allowed for the hello and the ack to cross the relays.
    static let relayMargin = 15
    /// B: seconds after scanning A in which its hello may still go out.
    static var helloWindow: Int { MeshPairing.ackWindow - MeshPairing.scanWindow - relayMargin }

    /// A: seconds left to tap Add, counted from the hello.
    static func secondsLeftForA(helloAt: Int, now: Int) -> Int {
        MeshPairing.scanWindow - (now - helloAt)
    }

    /// B: seconds left to tap Add (and say hello), counted from the scan.
    static func secondsLeftForB(scannedAt: Int, now: Int) -> Int {
        helloWindow - (now - scannedAt)
    }

    /// Whether a tap with this many seconds left may still store and send.
    static func mayConfirm(secondsLeft: Int) -> Bool { secondsLeft > 0 }
}

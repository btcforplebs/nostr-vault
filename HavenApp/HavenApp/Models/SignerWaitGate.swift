import Foundation

/// Whether the DM queue may ask a remote signer to open a gift wrap now.
///
/// A silent bunker used to be asked about every waiting wrap, one after the
/// other, on every retry round: 200 waiting DMs over 9 rounds was up to 1,800
/// connect and decrypt requests to a signer that was not answering. Now the
/// first "no answer" parks the whole queue. A retry round asks about one wrap
/// only (the probe); the rest wait until the signer answers it.
struct SignerWaitGate: Equatable {
    /// The signer did not answer: ask it about nothing until the next round.
    private(set) var parked = false
    /// The one wrap a retry round asks about.
    private(set) var probeId: String?

    /// Whether to ask the signer about this wrap now. No means: put it back
    /// with the waiting ones, no request.
    func mayAsk(_ id: String) -> Bool {
        guard !parked else { return false }
        return probeId == nil || probeId == id
    }

    /// The signer did not answer (timed out, offline, not connected).
    mutating func noAnswer() {
        parked = true
        probeId = nil
    }

    /// The signer answered (opened it, refused, or it could not be opened).
    /// True when that answer was the probe's, so every waiting wrap goes
    /// back to the signer now.
    mutating func answered(_ id: String) -> Bool {
        guard !parked else { return false }
        let wasProbe = probeId == id
        if wasProbe { probeId = nil }
        return wasProbe
    }

    /// A retry round while parked: ask about `id` only.
    mutating func probe(_ id: String) {
        parked = false
        probeId = id
    }

    mutating func reset() {
        self = SignerWaitGate()
    }
}

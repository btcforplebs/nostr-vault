import Foundation

/// Whether a DM you sent got through, from its relays' answers, the way the
/// web decides it (web-vault/src/net/dms.js sendMessage): it is sent the moment
/// the first of their relays takes it, and not sent once every one of them has
/// refused or timed out. Pure, so the rule is pinned by tests; DMService feeds
/// it the answers.
struct DMDelivery {
    enum Outcome: Equatable {
        /// The first relay of theirs took it.
        case delivered
        /// Every relay answered and none took it; the text is shown under the bubble.
        case failed(String)
    }

    /// How long a send may wait for any answer at all. A relay whose socket
    /// never connects never answers, so without this the bubble could say
    /// "Sending…" for good. Longer than one relay's own wait: 15 s in all for
    /// NIP-17, and for NIP-04 10 s that only start once the socket connects.
    static let deadline: TimeInterval = 30

    static func noRelays() -> String { "Not delivered: no relays found for them." }

    static func noneTookIt(_ count: Int) -> String {
        "Not delivered: none of their \(count) relay\(count == 1 ? "" : "s") took it."
    }

    static let timedOut = "Not delivered: their relays didn't answer."

    private let relayCount: Int
    private var answered = 0
    private(set) var outcome: Outcome?

    init(relayCount: Int) {
        self.relayCount = relayCount
        if relayCount == 0 { outcome = .failed(Self.noRelays()) }
    }

    /// Records one relay's answer. Returns the outcome only on the answer that
    /// decides it (later answers return nil), so the caller acts once.
    mutating func record(accepted: Bool) -> Outcome? {
        guard outcome == nil else { return nil }
        answered += 1
        if accepted {
            outcome = .delivered
        } else if answered >= relayCount {
            outcome = .failed(Self.noneTookIt(relayCount))
        }
        return outcome
    }

    /// The deadline passed: not sent, unless a relay already took it.
    mutating func expire() -> Outcome? {
        guard outcome == nil else { return nil }
        outcome = .failed(Self.timedOut)
        return outcome
    }
}

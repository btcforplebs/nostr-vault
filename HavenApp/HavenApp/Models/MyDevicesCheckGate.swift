import Foundation

/// When Your space › My devices looks at the finder relays again.
///
/// A look runs for up to a few seconds. One asked for while it ran used to be
/// dropped, so a device added during a check stayed unchecked until the next
/// round, five minutes later. Now the caller waits for the running look to
/// end and then asks again: it looks if the devices changed.
struct MyDevicesCheckGate {
    enum Decision: Equatable {
        case look
        /// A look is running: ask again once it ends.
        case wait
        /// The same devices were looked at moments ago.
        case skip
    }

    /// Skip a look at the same devices made this recently.
    static let sameSetPause: TimeInterval = 60

    private(set) var checking = false
    private(set) var lastAsked: Set<String> = []
    private(set) var lastLook: Date = .distantPast

    /// `.look` marks a look as running until `finish`.
    mutating func begin(asked: Set<String>, force: Bool, now: Date) -> Decision {
        if checking { return .wait }
        guard force || asked != lastAsked || now.timeIntervalSince(lastLook) > Self.sameSetPause else { return .skip }
        checking = true
        return .look
    }

    mutating func finish(asked: Set<String>, now: Date) {
        checking = false
        lastAsked = asked
        lastLook = now
    }
}

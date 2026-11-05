import XCTest
@testable import MediaLogic

/// The notification prompt: once, after you're in, never over a card.
final class NotificationAskTests: XCTestCase {
    private let quiet = NotificationAsk.quietSeconds

    func testAnsweredBeforeNeverPromptsAgain() {
        XCTAssertEqual(NotificationAsk.action(undecided: false, inApp: true, busy: false, quietFor: 60), .alreadyAnswered)
        XCTAssertEqual(NotificationAsk.action(undecided: false, inApp: false, busy: true, quietFor: 0), .alreadyAnswered)
    }

    /// Setup, its tour, and the moment before the Mac window: not in yet.
    func testNotBeforeYouAreIn() {
        XCTAssertEqual(NotificationAsk.action(undecided: true, inApp: false, busy: false, quietFor: 60), .wait)
    }

    func testNotOverATutorialCard() {
        XCTAssertEqual(NotificationAsk.action(undecided: true, inApp: true, busy: true, quietFor: 60), .wait)
    }

    /// A card that just closed can hand over to the next one: wait a moment.
    func testWaitsForAQuietMoment() {
        XCTAssertEqual(NotificationAsk.action(undecided: true, inApp: true, busy: false, quietFor: quiet - 0.1), .wait)
        XCTAssertEqual(NotificationAsk.action(undecided: true, inApp: true, busy: false, quietFor: quiet), .ask)
    }
}

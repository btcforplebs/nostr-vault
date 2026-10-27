import XCTest
@testable import MediaLogic

/// 3.0.1 #7: an alert used to fire on the relay's marker, before the note or
/// its author could draw ("Someone mentioned you", a badge, a blank pill).
final class NotificationReadinessTests: XCTestCase {

    func testNoteAlertsWaitForTheNoteAndItsAuthor() {
        for type in ["mention", "reply", "quote", "reaction", "repost", "zap"] {
            XCTAssertEqual(NotificationReadiness.needs(type: type),
                           .init(note: true, profile: true, avatar: true), type)
        }
    }

    func testPeopleAlertsWaitForThePersonOnly() {
        for type in ["dm", "giftwrap", "follow"] {
            XCTAssertEqual(NotificationReadiness.needs(type: type),
                           .init(note: false, profile: true, avatar: true), type)
        }
    }

    func testNamelessAlertsDoNotWait() {
        for type in ["summary", "followers"] {
            XCTAssertEqual(NotificationReadiness.needs(type: type),
                           .init(note: false, profile: false, avatar: false), type)
        }
    }

    /// The gate holds until the check flips, not one poll less.
    func testWaitReturnsOnlyOnceReady() async {
        var asks = 0
        let ready = await NotificationReadiness.wait(timeout: 5, interval: 0.01) {
            asks += 1
            return asks >= 4
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(asks, 4)
    }

    /// A profile that never loads still lets the alert out, at the bound.
    func testWaitGivesUpAtTheBound() async {
        let start = Date()
        let ready = await NotificationReadiness.wait(timeout: 0.1, interval: 0.02) { false }
        XCTAssertFalse(ready)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testReadyAtOnceDoesNotWait() async {
        let start = Date()
        let ready = await NotificationReadiness.wait(timeout: 5) { true }
        XCTAssertTrue(ready)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }
}

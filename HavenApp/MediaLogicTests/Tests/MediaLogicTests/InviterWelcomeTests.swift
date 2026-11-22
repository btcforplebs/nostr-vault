import XCTest
@testable import MediaLogic

/// The new account's inviter card: who, for which account, for how long.
final class InviterWelcomeTests: XCTestCase {
    private func k(_ n: Int) -> String { String(format: "%064x", n) }
    private func store() -> InviterWelcome {
        InviterWelcome(defaults: UserDefaults(suiteName: "InviterWelcomeTests-\(UUID().uuidString)")!)
    }

    func testShownForThatAccountForADay() {
        let w = store(), t0 = Date(timeIntervalSince1970: 1_800_000_000)
        w.start(account: k(1).uppercased(), inviter: k(2), now: t0)
        XCTAssertEqual(w.inviter(for: k(1), now: t0.addingTimeInterval(60)), k(2))
        XCTAssertNil(w.inviter(for: k(3), now: t0), "another account")
        XCTAssertNil(w.inviter(for: k(1), now: t0.addingTimeInterval(InviterWelcome.lifetime)), "after a day")
    }

    func testWavedOrClosedHidesIt() {
        let w = store(), t0 = Date()
        w.start(account: k(1), inviter: k(2), now: t0)
        w.markWaved()
        XCTAssertNil(w.inviter(for: k(1), now: t0))
        w.start(account: k(1), inviter: k(2), now: t0)
        w.close()
        XCTAssertNil(w.inviter(for: k(1), now: t0))
    }

    func testNoInviterOrYourselfOrJunkClearsIt() {
        let w = store()
        w.start(account: k(1), inviter: k(2))
        w.start(account: k(1), inviter: nil)
        XCTAssertNil(w.entry)
        w.start(account: k(1), inviter: k(1))
        XCTAssertNil(w.entry)
        w.start(account: k(1), inviter: "npub1nope")
        XCTAssertNil(w.entry)
    }

    func testWaveMentionsTheInviter() {
        XCTAssertEqual(InviterWelcome.waveContent(inviterNpub: "npub1abc"), "👋 nostr:npub1abc")
        XCTAssertEqual(InviterWelcome.waveTags(inviter: k(2).uppercased()), [["p", k(2)]])
    }
}

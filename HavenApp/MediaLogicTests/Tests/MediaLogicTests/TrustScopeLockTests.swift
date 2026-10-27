import XCTest
@testable import MediaLogic

/// The Everyone switch unlocks at five follows, and never takes Everyone
/// away from someone who already has it on.
final class TrustScopeLockTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private func key(_ n: Int) -> String { String(format: "%064x", n) }

    func testCountsEachFollowOnceWithoutYourself() {
        XCTAssertEqual(TrustScopeLock.followCount([key(1), key(2), key(2), me, key(3).uppercased(), key(3)], me: me), 3)
        XCTAssertEqual(TrustScopeLock.followCount([], me: me), 0)
    }

    func testLockedBelowFiveFollows() {
        for n in 0..<5 {
            XCTAssertTrue(TrustScopeLock.isLocked(followCount: n, everyoneIsOn: false), "\(n) follows")
        }
        XCTAssertFalse(TrustScopeLock.isLocked(followCount: 5, everyoneIsOn: false))
        XCTAssertFalse(TrustScopeLock.isLocked(followCount: 500, everyoneIsOn: false))
    }

    func testEveryoneAlreadyOnIsKept() {
        XCTAssertFalse(TrustScopeLock.isLocked(followCount: 0, everyoneIsOn: true))
    }

    func testProgressText() {
        XCTAssertEqual(TrustScopeLock.progressText(followCount: 0), "Follow 5 more people to unlock Everyone")
        XCTAssertEqual(TrustScopeLock.progressText(followCount: 2), "Follow 3 more people to unlock Everyone")
        XCTAssertEqual(TrustScopeLock.progressText(followCount: 4), "Follow 1 more person to unlock Everyone")
        XCTAssertEqual(TrustScopeLock.progressText(followCount: 9), "Everyone is unlocked")
    }
}

import XCTest
@testable import MediaLogic

/// The app doesn't sell articles: the lock card names no price and no way to
/// pay. Only a Fanfares article points to Fanfares.
final class GatedLockCopyTests: XCTestCase {
    func testLockCopyOffersNoPayment() {
        let text = GatedLockCopy.status(author: "Alice")
        XCTAssertTrue(text.contains("Alice"), text)
        for word in ["sats", "zap", "pay", "web", "unlock it", "Already", "Fanfares"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(word): \(text)")
        }
    }

    func testFanfaresCopyPointsToFanfaresWithoutAPrice() {
        let text = GatedLockCopy.fanfaresStatus(author: "Alice", failure: nil)
        XCTAssertTrue(text.contains("Alice"), text)
        XCTAssertTrue(text.contains("Fanfares"), text)
        XCTAssertTrue(text.contains("Already unlocked?"), text)
        for word in ["sats", "zap", "pay"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(word): \(text)")
        }
    }

    func testFanfaresCopyShowsAFailedCheck() {
        XCTAssertEqual(GatedLockCopy.fanfaresStatus(author: "Alice", failure: "Nope."), "Nope.")
    }
}

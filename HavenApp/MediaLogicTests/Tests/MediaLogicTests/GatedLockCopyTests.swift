import XCTest
@testable import MediaLogic

/// The app doesn't sell articles: the lock card names no price, no place to
/// buy and no way to pay.
final class GatedLockCopyTests: XCTestCase {
    func testLockCopyOffersNoPayment() {
        let text = GatedLockCopy.status(author: "Alice")
        XCTAssertTrue(text.contains("Alice"), text)
        for word in ["sats", "zap", "pay", "web", "unlock it", "Already paid"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(word): \(text)")
        }
    }
}

import XCTest
@testable import MediaLogic

/// Where the app can't pay for a locked article (iOS), the lock card must
/// not steer to where it is sold: no price, no link out, no "pay elsewhere".
final class GatedLockCopyTests: XCTestCase {
    private let link = URL(string: "https://example.com/buy")!
    private let ios = GatedLockCopy(paysHere: false)
    private let mac = GatedLockCopy(paysHere: true)

    private func statuses(_ copy: GatedLockCopy) -> [String] {
        [copy.status(author: "Alice", priceSats: 2100, paid: false, fullyPaid: false, failure: nil, waiting: false),
         copy.status(author: "Alice", priceSats: 2100, paid: true, fullyPaid: false, failure: nil, waiting: false)]
    }

    func testNoPriceOrLinkWhereTheAppCannotPay() {
        XCTAssertFalse(ios.showsPrice)
        XCTAssertNil(ios.webLink(authorLink: link))
    }

    func testIOSCopyNamesNoPriceAndNoOtherPlaceToPay() {
        for text in statuses(ios) {
            XCTAssertFalse(text.contains("2100"), text)
            XCTAssertFalse(text.contains("sats"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("web"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("another app"), text)
            XCTAssertTrue(text.contains("Already paid?"), text)
        }
    }

    func testMacKeepsPriceLinkAndZapCopy() {
        XCTAssertTrue(mac.showsPrice)
        XCTAssertEqual(mac.webLink(authorLink: link), link)
        XCTAssertEqual(statuses(mac), ["Zap Alice 2100 sats to read the full article here.",
                                       "Part of the price went through. Zap the rest to unlock."])
    }

    func testFailureAndWaitingWinOnBoth() {
        for copy in [ios, mac] {
            XCTAssertEqual(copy.status(author: "A", priceSats: 1, paid: true, fullyPaid: true, failure: "boom", waiting: false), "boom")
            XCTAssertTrue(copy.status(author: "A", priceSats: 1, paid: true, fullyPaid: true, failure: nil, waiting: true).hasPrefix("Paid."))
        }
    }
}

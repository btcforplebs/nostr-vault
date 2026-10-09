import XCTest
@testable import MediaLogic

final class Bolt11Tests: XCTestCase {

    func testOrdinaryInvoices() {
        XCTAssertEqual(Bolt11.amount("lnbc2500u1pvjluez"), .sats(250_000))
        XCTAssertEqual(Bolt11.amount("lnbc10n1pvjluez"), .sats(1))
        XCTAssertEqual(Bolt11.amount("lnbc1m1pvjluez"), .sats(100_000))
        XCTAssertEqual(Bolt11.amount("lntb20m1pvjluez"), .sats(2_000_000))
        XCTAssertEqual(Bolt11.amount("  LNBC330N1PVJLUEZ  "), .sats(33))
    }

    /// The separator is the last `1`, not the first digits after the prefix,
    /// so an amount containing a 1 survives.
    func testAmountsContainingAOne() {
        XCTAssertEqual(Bolt11.amount("lnbc1500n1pvjluez"), .sats(150))
        XCTAssertEqual(Bolt11.amount("lnbc21u1pvjluez"), .sats(2_100))
        XCTAssertEqual(Bolt11.amount("lnbc11m1pvjluez"), .sats(1_100_000))
    }

    /// An amountless invoice is `lnbc` + separator + data. Reading digits
    /// forward from the prefix made these 1 BTC and 100 sats respectively.
    func testAmountlessIsUnspecifiedWhateverTheDataStartsWith() {
        XCTAssertEqual(Bolt11.amount("lnbc1qqqqsyqcyq5rqwzqfqypqdq5"), .unspecified)
        XCTAssertEqual(Bolt11.amount("lnbc1u3qqqsyqcyq5rqwzqfqypq"), .unspecified)
        XCTAssertEqual(Bolt11.amount("lnbc1n3qqqsyqcyq5rqwzqfqypq"), .unspecified)
        XCTAssertEqual(Bolt11.amount("lntb1qqqqsyqcyq5rqwzqfqypqdq5"), .unspecified)
    }

    /// Under a sat is a real amount we cannot show as sats — distinct from
    /// junk, because it must not be reported as "not an invoice".
    func testUnderASat() {
        XCTAssertEqual(Bolt11.amount("lnbc1p1pvjluez"), .unspecified)
        XCTAssertEqual(Bolt11.amount("lnbc100p1pvjluez"), .unspecified)
        XCTAssertEqual(Bolt11.amount("lnbc10000p1pvjluez"), .sats(1))
    }

    func testJunk() {
        XCTAssertEqual(Bolt11.amount("not-an-invoice"), .unreadable)
        XCTAssertEqual(Bolt11.amount(""), .unreadable)
        XCTAssertEqual(Bolt11.amount("lnbc"), .unreadable)          // no separator
        XCTAssertEqual(Bolt11.amount("lnbc330n1"), .unreadable)     // no data part
        XCTAssertEqual(Bolt11.amount("bc1qxyzzy"), .unreadable)     // an on-chain address
        XCTAssertEqual(Bolt11.amount("lnbc10x1pvjluez"), .unreadable) // not a multiplier
    }

    /// `*` traps on overflow in Swift, and the digit run is unbounded input.
    func testAbsurdAmounts() {
        XCTAssertEqual(Bolt11.amount("lnbc99999999999999999m1pvjluez"), .unreadable)
        XCTAssertEqual(Bolt11.amount("lnbc999999999999999999999999991pvjluez"), .unreadable)
        XCTAssertEqual(Bolt11.amount("lnbc21000000001pvjluez"), .unreadable)
    }

    func testSatsConvenienceMatchesTheClassifier() {
        XCTAssertEqual(Bolt11.sats("lnbc330n1pvjluez"), 33)
        XCTAssertNil(Bolt11.sats("lnbc1qqqqsyqcyq5rqwzqfqypqdq5"))
        XCTAssertNil(Bolt11.sats("not-an-invoice"))
    }
}

final class Bolt11MsatTests: XCTestCase {
    /// The exact amount, so a payer can refuse an invoice that is off by
    /// less than a sat — `amount` rounds that away.
    func testExactMsat() {
        XCTAssertEqual(Bolt11.msat("lnbc210n1pvjluez"), 21_000)
        XCTAssertEqual(Bolt11.msat("lnbc210010p1pvjluez"), 21_001)
        XCTAssertEqual(Bolt11.amount("lnbc210010p1pvjluez"), .sats(21))
        XCTAssertNotEqual(Bolt11.msat("lnbc210010p1pvjluez"), 21_000)
    }

    func testNoExactMsat() {
        XCTAssertNil(Bolt11.msat("lnbc1qqqqsyqcyq5rqwzqfqypqdq5"))   // amountless
        XCTAssertNil(Bolt11.msat("lnbc1p1pvjluez"))                  // a tenth of a msat
        XCTAssertNil(Bolt11.msat("not-an-invoice"))
    }
}

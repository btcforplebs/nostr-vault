import XCTest
@testable import MediaLogic

/// Bug hunt 2026-11-05 #1: a zap paid whatever invoice the server sent back.
final class ZapInvoiceCheckTests: XCTestCase {
    /// 2,100 sats, made 2025-10-27 16:00Z, 1 h expiry (NoteInvoicesTests).
    let coffee = "lnbc21u1p50l9cqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdq6gdhkven9v5sxvmmjypxx7em9dcxqrrssqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsz8ap9"
    /// Amountless.
    let tipJar = "lnbc1p50l9cqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdqv235hqgr2v9eqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7aq7d0"
    let made = Date(timeIntervalSince1970: 1_761_580_800)

    func testExactAmountInTimePays() {
        XCTAssertNil(ZapInvoiceCheck.problem(invoice: coffee, amountMsat: 2_100_000, now: made.addingTimeInterval(60)))
    }

    /// A 21-sat zap must never pay a bigger invoice (or a smaller one, or
    /// one with no amount the wallet would fill in).
    func testWrongAmountIsRefused() {
        XCTAssertEqual(ZapInvoiceCheck.problem(invoice: coffee, amountMsat: 21_000, now: made), .wrongAmount)
        XCTAssertEqual(ZapInvoiceCheck.problem(invoice: coffee, amountMsat: 2_100_001, now: made), .wrongAmount)
        XCTAssertEqual(ZapInvoiceCheck.problem(invoice: tipJar, amountMsat: 21_000, now: made), .wrongAmount)
        XCTAssertEqual(ZapInvoiceCheck.problem(invoice: "garbage", amountMsat: 21_000, now: made), .wrongAmount)
    }

    func testExpiredIsRefused() {
        XCTAssertEqual(ZapInvoiceCheck.problem(invoice: coffee, amountMsat: 2_100_000, now: made.addingTimeInterval(3600)), .expired)
    }
}

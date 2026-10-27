import XCTest
@testable import MediaLogic

/// Invoices built for these tests (zeroed signature, valid checksum): see
/// the field values in each name.
final class NoteInvoicesTests: XCTestCase {
    /// 2,100 sats, "Coffee for Logen", made 2025-10-27 16:00Z, 1 h expiry.
    let coffee = "lnbc21u1p50l9cqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdq6gdhkven9v5sxvmmjypxx7em9dcxqrrssqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsz8ap9"
    /// Amountless, "Tip jar", same time, no `x` field.
    let tipJar = "lnbc1p50l9cqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdqv235hqgr2v9eqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7aq7d0"
    /// 150 sats, "old one", made 2017-07-14, 60 s expiry.
    let stale = "lnbc1500n1pvkstcqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdqvdakxggr0dejsxqzpuqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqmtms8k"
    /// 500 sats, "Sim card ☕", 1 day expiry — a multi-byte memo.
    let cup = "lnbc5000n1p4wpj5qpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdq52d5k6grrv9exgg8znz2sxqyz5vqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqtdpp0"

    let made = Date(timeIntervalSince1970: 1_761_580_800)

    func testDetailsReadAmountMemoAndExpiry() throws {
        let d = try XCTUnwrap(Bolt11.details(coffee))
        XCTAssertEqual(d.amount, .sats(2_100))
        XCTAssertEqual(d.memo, "Coffee for Logen")
        XCTAssertEqual(d.createdAt, made)
        XCTAssertEqual(d.expiresAt, made.addingTimeInterval(3600))
        XCTAssertFalse(d.isExpired(at: made.addingTimeInterval(3599)))
        XCTAssertTrue(d.isExpired(at: made.addingTimeInterval(3600)))
    }

    func testExpired() throws {
        let d = try XCTUnwrap(Bolt11.details(stale))
        XCTAssertEqual(d.amount, .sats(150))
        XCTAssertEqual(d.expiresAt.timeIntervalSince(d.createdAt), 60)
        XCTAssertTrue(d.isExpired(at: made))
    }

    func testNoAmountAndDefaultExpiry() throws {
        let d = try XCTUnwrap(Bolt11.details(tipJar))
        XCTAssertEqual(d.amount, .unspecified)
        XCTAssertEqual(d.memo, "Tip jar")
        XCTAssertEqual(d.expiresAt, made.addingTimeInterval(Bolt11.defaultExpiry))
    }

    func testUppercase() throws {
        XCTAssertEqual(Bolt11.details(coffee.uppercased()), Bolt11.details(coffee))
        let found = NoteInvoices.find(in: "Pay me: LIGHTNING:\(coffee.uppercased()) thanks")
        XCTAssertEqual(found.map(\.invoice), [coffee])
        XCTAssertEqual(found.first?.raw, "LIGHTNING:\(coffee.uppercased())")
    }

    func testMultiByteMemo() {
        XCTAssertEqual(Bolt11.details(cup)?.memo, "Sim card ☕")
        XCTAssertEqual(Bolt11.details(cup)?.amount, .sats(500))
    }

    func testFindInNoteTextAndStrip() {
        let note = "Coffee fund ⚡\n\nlightning:\(coffee)\n\nor \(tipJar)\nagain \(coffee)"
        let found = NoteInvoices.find(in: note)
        XCTAssertEqual(found.map(\.invoice), [coffee, tipJar])  // each once
        XCTAssertEqual(NoteInvoices.strip(found, from: note)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " "),
            "Coffee fund ⚡    or  again")
    }

    func testLookalikesStayText() {
        XCTAssertTrue(NoteInvoices.find(in: "lnbc21u1pvjluez is short").isEmpty)        // truncated
        XCTAssertTrue(NoteInvoices.find(in: "x\(coffee)").isEmpty)                      // glued to a word
        XCTAssertNil(Bolt11.details("lnbc21u1" + String(repeating: "b", count: 130)))   // not bech32
        XCTAssertTrue(NoteInvoices.find(in: "no lightning here").isEmpty)
    }
}

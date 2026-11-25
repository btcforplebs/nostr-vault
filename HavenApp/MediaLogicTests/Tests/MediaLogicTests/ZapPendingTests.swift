import XCTest
@testable import MediaLogic

/// Zaps that went through but looked failed (Minibits review, 2026-11-19).
final class ZapPendingTests: XCTestCase {
    let server = "beeb4840aaaa"
    let requestId = "9734aaaa"
    let invoice = "lnbc100u1pzapinvoice"

    private func receipt(bolt11: String? = nil, describedId: String? = nil) -> [[String]] {
        var tags: [[String]] = [["p", "recipient"], ["e", "note"]]
        if let bolt11 { tags.append(["bolt11", bolt11]) }
        if let describedId { tags.append(["description", #"{"kind":9734,"id":"\#(describedId)","tags":[]}"#]) }
        return tags
    }

    // Bug 1: the wait.

    /// Receipt minus request on 2026-11-19: 15, 24, 37 and 96 s; the wallet's 15 s called them all failed.
    func testPaidZapsOf96SecondsAreStillCaught() {
        XCTAssertGreaterThanOrEqual(ZapWait.reply, 37, "most paid zaps get the wallet's answer")
        XCTAssertGreaterThanOrEqual(ZapWait.receipt, 96, "the slowest receipt is still looked for")
        XCTAssertGreaterThan(ZapWait.receipt, ZapWait.reply, "the receipt is still looked for after the wallet's wait ends")
    }

    /// Minibits answers NWC from a push and can take minutes to wake (cashu design §6c): after the
    /// 90 s reply wait, the receipt is still looked for until the pending zap's 10 minutes are up.
    func testReceiptIsLookedForTenMinutes() {
        XCTAssertEqual(ZapWait.receipt, 600, "slow-waking wallets get 10 minutes")
        XCTAssertEqual(ZapWait.receipt, ZapPendingGuard.window, "the pill and the second-zap guard end together")
    }

    func testNoAnswerAfterSendingIsPendingNotFailed() {
        XCTAssertEqual(ZapWaitOutcome.noAnswer(requestSent: true), .pending)
        XCTAssertEqual(ZapWaitOutcome.noAnswer(requestSent: false), .failed, "nothing reached the wallet")
    }

    // Bug 2: which receipt is ours.

    func testReceiptMatchesByInvoiceOrByOurRequest() {
        XCTAssertTrue(ZapReceiptMatch.matches(receiptPubkey: server, tags: receipt(bolt11: invoice), zapRequestId: requestId,
                                              invoice: invoice, publisher: server))
        XCTAssertTrue(ZapReceiptMatch.matches(receiptPubkey: server, tags: receipt(bolt11: invoice.uppercased()), zapRequestId: requestId,
                                              invoice: invoice, publisher: server), "bolt11 is case-insensitive")
        XCTAssertTrue(ZapReceiptMatch.matches(receiptPubkey: server, tags: receipt(describedId: requestId), zapRequestId: requestId,
                                              invoice: invoice, publisher: server))
    }

    func testSomeoneElsesZapToTheSameNoteIsNotOurs() {
        XCTAssertFalse(ZapReceiptMatch.matches(receiptPubkey: server, tags: receipt(bolt11: "lnbc1other", describedId: "otherreq"),
                                               zapRequestId: requestId, invoice: invoice, publisher: server))
        XCTAssertFalse(ZapReceiptMatch.matches(receiptPubkey: server, tags: receipt(), zapRequestId: requestId,
                                               invoice: invoice, publisher: server), "no bolt11, no description")
    }

    func testAReceiptFromAnyoneButTheZapServerIsNotTrusted() {
        XCTAssertFalse(ZapReceiptMatch.matches(receiptPubkey: "spoofer", tags: receipt(bolt11: invoice, describedId: requestId),
                                               zapRequestId: requestId, invoice: invoice, publisher: server))
        XCTAssertTrue(ZapReceiptMatch.matches(receiptPubkey: "anyone", tags: receipt(describedId: requestId),
                                              zapRequestId: requestId, invoice: invoice, publisher: nil),
                      "a server that names no publisher: same trust as ZapValidationService")
    }

    func testEmptyIdsNeverMatch() {
        XCTAssertFalse(ZapReceiptMatch.matches(receiptPubkey: server, tags: receipt(bolt11: "", describedId: ""),
                                               zapRequestId: "", invoice: "", publisher: server))
    }

    // Bug 3: ask before zapping the same thing again.

    func testASecondZapToTheSameNoteAsksUntilConfirmedOrTheWindowPasses() {
        var guardrail = ZapPendingGuard()
        let start = Date(timeIntervalSince1970: 1_795_098_000)
        let note = ZapPendingGuard.key(noteId: "ABC", address: nil, pubkey: "pk")
        XCTAssertFalse(guardrail.isPending(note, now: start))
        guardrail.begin(note, now: start)
        XCTAssertTrue(guardrail.isPending(note, now: start.addingTimeInterval(26)), "the 2x 1,000 sats, 26 s apart")
        XCTAssertTrue(guardrail.isPending(ZapPendingGuard.key(noteId: "abc", address: nil, pubkey: "other"), now: start), "same note")
        XCTAssertFalse(guardrail.isPending(ZapPendingGuard.key(noteId: "def", address: nil, pubkey: "pk"), now: start), "another note")
        XCTAssertFalse(guardrail.isPending(note, now: start.addingTimeInterval(ZapPendingGuard.window)))
        guardrail.end(note)
        XCTAssertFalse(guardrail.isPending(note, now: start.addingTimeInterval(1)), "receipt seen: no more asking")
    }

    func testKeysForStreamsAndPeople() {
        XCTAssertEqual(ZapPendingGuard.key(noteId: "", address: "30311:pk:d", pubkey: "pk"), "a:30311:pk:d")
        XCTAssertEqual(ZapPendingGuard.key(noteId: "", address: nil, pubkey: "PK"), "p:pk")
        XCTAssertNotEqual(ZapPendingGuard.key(noteId: "", address: nil, pubkey: "a"), ZapPendingGuard.key(noteId: "", address: nil, pubkey: "b"))
    }

    // Bug 5: zap lines in relay.log.

    func testZapAndNWCLinesAreKeptInTheRelaysShape() {
        XCTAssertTrue(ZapLogLine.isZapLine("Zap: Starting zap for a@b.c (21 sats)"))
        XCTAssertTrue(ZapLogLine.isZapLine("NWC: Connecting to wss://relay"))
        XCTAssertFalse(ZapLogLine.isZapLine("Feed: loaded"))
        let line = ZapLogLine.line("NWC: two\nlines", level: "warn", at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(line.hasSuffix(" WARN NWC: two lines\n"), line)
        XCTAssertNotNil(line.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} "#, options: .regularExpression),
                        "the relay's own time shape, which RelayLogParser strips")
    }
}

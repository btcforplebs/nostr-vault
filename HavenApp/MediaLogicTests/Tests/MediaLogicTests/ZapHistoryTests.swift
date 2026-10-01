import XCTest
@testable import MediaLogic

final class ZapHistoryTests: XCTestCase {

    // BOLT-11 spec example; its payment hash is 0001020304…0102.
    private let specInvoice = "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql"
    private let specHash = "0001020304050607080900010203040506070809000102030405060708090102"

    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)
    private let post = String(repeating: "e", count: 64)

    func testPaymentHash() {
        XCTAssertEqual(Bolt11.paymentHash(specInvoice), specHash)
        XCTAssertEqual(Bolt11.paymentHash(specInvoice.uppercased()), specHash)
        // Only the data part is read, so a stray prefix does not matter.
        XCTAssertEqual(Bolt11.paymentHash("lightning:" + specInvoice), specHash)
        XCTAssertNil(Bolt11.paymentHash("lnbc1qqqq"))
        XCTAssertNil(Bolt11.paymentHash("not an invoice"))
    }

    private func zapRequest(from: String, to: String, post: String?, content: String = "", anon: Bool = false) -> String {
        var tags: [[String]] = [["p", to], ["amount", "21000"], ["relays", "wss://x"]]
        if let post { tags.append(["e", post]) }
        if anon { tags.append(["anon"]) }
        let obj: [String: Any] = ["kind": 9734, "pubkey": from, "content": content, "tags": tags, "created_at": 1, "id": "x", "sig": "y"]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testZapRequestParsing() {
        let d = ZapDetail.fromZapRequest(json: zapRequest(from: alice, to: bob, post: post, content: " great shot "))
        XCTAssertEqual(d?.senderPubkey, alice)
        XCTAssertEqual(d?.recipientPubkey, bob)
        XCTAssertEqual(d?.postId, post)
        XCTAssertEqual(d?.comment, "great shot")
        XCTAssertEqual(d?.isAnonymous, false)
    }

    func testProfileZapHasNoPost() {
        let d = ZapDetail.fromZapRequest(json: zapRequest(from: alice, to: bob, post: nil))
        XCTAssertNil(d?.postId)
        XCTAssertNil(d?.comment)
    }

    func testPlainDescriptionsAreNotZaps() {
        XCTAssertNil(ZapDetail.fromZapRequest(json: "Payment to logen"))
        XCTAssertNil(ZapDetail.fromZapRequest(json: "{\"kind\":1,\"pubkey\":\"a\"}"))
        XCTAssertNil(ZapDetail.fromZapRequest(json: "{not json"))
    }

    func testCounterparty() {
        let d = ZapDetail.fromZapRequest(json: zapRequest(from: alice, to: bob, post: post))!
        XCTAssertEqual(d.counterparty(me: bob, direction: .incoming), alice)
        XCTAssertEqual(d.counterparty(me: alice, direction: .outgoing), bob)
        let anon = ZapDetail.fromZapRequest(json: zapRequest(from: alice, to: bob, post: post, anon: true))!
        XCTAssertNil(anon.counterparty(me: bob, direction: .incoming), "an anonymous zap's key is throwaway, not a person")
    }

    /// A wallet that hands back the zap request as the description: the row
    /// gets the zap, and never shows the raw JSON.
    func testTransactionWithZapRequestDescription() {
        let tx = WalletTransaction(nip47: [
            "type": "incoming", "created_at": 1, "amount": 21_000,
            "payment_hash": specHash, "description": zapRequest(from: alice, to: bob, post: post),
        ])
        XCTAssertEqual(tx?.zap?.senderPubkey, alice)
        XCTAssertNil(tx?.description)
    }

    func testPaymentHashFallsBackToTheInvoice() {
        let tx = WalletTransaction(nip47: ["type": "outgoing", "created_at": 1, "invoice": specInvoice])
        XCTAssertEqual(tx?.paymentHash, specHash)
    }

    func testReceiptParsingAndMatching() {
        let receipt = ZapReceipt(tags: [
            ["p", bob], ["e", post], ["bolt11", specInvoice.uppercased()],
            ["description", zapRequest(from: alice, to: bob, post: post, content: "nice")],
        ])
        XCTAssertEqual(receipt?.paymentHash, specHash)

        let byHash = WalletTransaction(nip47: ["type": "incoming", "created_at": 1, "payment_hash": specHash.uppercased()])!
        let byInvoice = WalletTransaction(id: "inv", direction: .incoming, state: .settled, amountSats: 1, feeSats: 0,
                                          description: nil, createdAt: Date(), settledAt: nil,
                                          paymentHash: nil, invoice: specInvoice)
        let other = WalletTransaction(nip47: ["type": "incoming", "created_at": 1, "payment_hash": String(repeating: "f", count: 64)])!

        let m = ZapReceipt.match([byHash, byInvoice, other], [receipt!])
        XCTAssertEqual(m[byHash.id]?.comment, "nice")
        XCTAssertEqual(m[byInvoice.id]?.senderPubkey, alice)
        XCTAssertNil(m[other.id])
    }

    /// A forger can copy a real receipt's bolt11 into a receipt of their own.
    /// Two receipts that disagree about one payment: neither is shown.
    func testConflictingReceiptsForOnePaymentShowNeither() {
        let real = ZapReceipt(tags: [["bolt11", specInvoice],
                                     ["description", zapRequest(from: alice, to: bob, post: post, content: "nice")]])!
        let fake = ZapReceipt(tags: [["bolt11", specInvoice],
                                     ["description", zapRequest(from: alice, to: bob, post: post, content: "refund me at evil")]])!
        let byHash = WalletTransaction(nip47: ["type": "incoming", "created_at": 1, "payment_hash": specHash])!
        let byInvoice = WalletTransaction(id: "inv", direction: .incoming, state: .settled, amountSats: 1, feeSats: 0,
                                          description: nil, createdAt: Date(), settledAt: nil,
                                          paymentHash: nil, invoice: specInvoice)
        XCTAssertTrue(ZapReceipt.match([byHash, byInvoice], [real, fake]).isEmpty)
        // The same receipt twice (it came back from two relays) is no conflict.
        XCTAssertEqual(ZapReceipt.match([byHash], [real, real])[byHash.id]?.comment, "nice")
    }

    /// The raw request is kept so the service can check its signature.
    func testZapDetailKeepsTheRequestText() {
        let json = zapRequest(from: alice, to: bob, post: nil)
        XCTAssertEqual(ZapDetail.fromZapRequest(json: "  " + json + "\n")?.requestJSON, json)
    }

    func testReceiptMissingPartsIsDropped() {
        XCTAssertNil(ZapReceipt(tags: [["bolt11", specInvoice]]))
        XCTAssertNil(ZapReceipt(tags: [["description", zapRequest(from: alice, to: bob, post: nil)]]))
    }
}

import XCTest
@testable import MediaLogic

final class LightningPayTargetTests: XCTestCase {

    // A real LUD-01 example: https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df
    private let lnurl = "LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS"

    func testInvoice() {
        XCTAssertEqual(LightningPayTarget.parse("lnbc2500u1pvjluez"), .invoice("lnbc2500u1pvjluez"))
        XCTAssertEqual(LightningPayTarget.parse("  LNBC2500U1PVJLUEZ\n"), .invoice("lnbc2500u1pvjluez"))
        XCTAssertEqual(LightningPayTarget.parse("lightning:lnbc2500u1pvjluez"), .invoice("lnbc2500u1pvjluez"))
        XCTAssertEqual(LightningPayTarget.parse("LIGHTNING:LNBC2500U1PVJLUEZ"), .invoice("lnbc2500u1pvjluez"))
        XCTAssertEqual(LightningPayTarget.parse("lightning://lnbc2500u1pvjluez"), .invoice("lnbc2500u1pvjluez"))
        XCTAssertEqual(LightningPayTarget.parse("lntb20m1pvjluez"), .invoice("lntb20m1pvjluez"))
    }

    func testBIP21CarriesTheLightningParameter() {
        XCTAssertEqual(
            LightningPayTarget.parse("bitcoin:bc1qxyz?amount=0.0001&lightning=LNBC10U1PVJLUEZ&label=x"),
            .invoice("lnbc10u1pvjluez")
        )
        // On-chain only: nothing this wallet can pay.
        XCTAssertNil(LightningPayTarget.parse("bitcoin:bc1qxyz?amount=0.0001"))
    }

    func testLightningAddress() {
        XCTAssertEqual(LightningPayTarget.parse("Logen@getalby.com"), .address("logen@getalby.com"))
        XCTAssertEqual(LightningPayTarget.parse(" lightning:satoshi@walletofsatoshi.com "), .address("satoshi@walletofsatoshi.com"))
        XCTAssertEqual(LightningPayTarget.parse("first.last+tip@pay.example.co.uk"), .address("first.last+tip@pay.example.co.uk"))
        XCTAssertNil(LightningPayTarget.parse("no-domain@"))
        XCTAssertNil(LightningPayTarget.parse("@domain.com"))
        XCTAssertNil(LightningPayTarget.parse("user@localhost"))
        XCTAssertNil(LightningPayTarget.parse("two@at@signs.com"))
        XCTAssertNil(LightningPayTarget.parse("has space@domain.com"))
    }

    func testBech32LNURL() {
        XCTAssertEqual(LightningPayTarget.parse(lnurl), .lnurl(lnurl.lowercased()))
        XCTAssertEqual(LightningPayTarget.parse("lightning:" + lnurl), .lnurl(lnurl.lowercased()))
    }

    func testLUD17Links() {
        XCTAssertEqual(LightningPayTarget.parse("lnurlp://pay.example.com/lnurlp/abc"),
                       .lnurlURL(URL(string: "https://pay.example.com/lnurlp/abc")!))
        XCTAssertEqual(LightningPayTarget.parse("lnurlw://atm.example.com/w?k1=1"),
                       .lnurlURL(URL(string: "https://atm.example.com/w?k1=1")!))
        XCTAssertEqual(LightningPayTarget.parse("lnurlp://abcdef.onion/p"),
                       .lnurlURL(URL(string: "http://abcdef.onion/p")!))
    }

    func testJunk() {
        XCTAssertNil(LightningPayTarget.parse(""))
        XCTAssertNil(LightningPayTarget.parse("   "))
        XCTAssertNil(LightningPayTarget.parse("hello"))
        XCTAssertNil(LightningPayTarget.parse("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx"))
        XCTAssertNil(LightningPayTarget.parse("https://example.com"))
    }

    // MARK: - Amount range

    func testAmountRange() {
        let r = LNURLAmountRange(minMsat: 1_000, maxMsat: 100_000_000)
        XCTAssertEqual(r.check(sats: 21), .ok(msat: 21_000))
        XCTAssertEqual(r.check(sats: 1), .ok(msat: 1_000))
        XCTAssertEqual(r.check(sats: 100_000), .ok(msat: 100_000_000))
        XCTAssertEqual(r.check(sats: 100_001), .tooLarge(maxSats: 100_000))
        XCTAssertEqual(r.check(sats: 0), .invalid)
        XCTAssertEqual(r.check(sats: nil), .invalid)
        XCTAssertFalse(r.isFixed)
    }

    /// Bounds that are not whole sats round inwards, so the sat amount the
    /// user is offered is always one the service will take.
    func testFractionalBoundsRoundInwards() {
        let r = LNURLAmountRange(minMsat: 1_500, maxMsat: 9_999)
        XCTAssertEqual(r.minSats, 2)
        XCTAssertEqual(r.maxSats, 9)
        XCTAssertEqual(r.check(sats: 1), .tooSmall(minSats: 2))
        XCTAssertEqual(r.check(sats: 2), .ok(msat: 2_000))
        XCTAssertEqual(r.check(sats: 10), .tooLarge(maxSats: 9))
    }

    func testFixedAmount() {
        XCTAssertTrue(LNURLAmountRange(minMsat: 50_000, maxMsat: 50_000).isFixed)
    }

    // MARK: - History

    func testTransactionDecoding() {
        let t = WalletTransaction(nip47: [
            "type": "incoming", "state": "settled", "invoice": "lnbc1",
            "description": "  coffee ", "payment_hash": "abc", "amount": 21_000,
            "fees_paid": 0, "created_at": 1_700_000_000, "settled_at": 1_700_000_005,
        ])
        XCTAssertEqual(t?.id, "abc")
        XCTAssertEqual(t?.direction, .incoming)
        XCTAssertEqual(t?.state, .settled)
        XCTAssertEqual(t?.amountSats, 21)
        XCTAssertEqual(t?.description, "coffee")
        XCTAssertEqual(t?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Wallets disagree on number types; a string or double amount must not
    /// read as zero.
    func testLooseNumberTypes() {
        let t = WalletTransaction(nip47: [
            "type": "outgoing", "payment_hash": "h", "amount": "5000",
            "fees_paid": 2000.0, "created_at": 1_700_000_000.0,
        ])
        XCTAssertEqual(t?.amountSats, 5)
        XCTAssertEqual(t?.feeSats, 2)
        XCTAssertEqual(t?.direction, .outgoing)
    }

    /// No `state` field (older NIP-47 wallets): settled_at decides.
    func testStateFallsBackToSettledAt() {
        let settled = WalletTransaction(nip47: ["type": "outgoing", "amount": 1000, "created_at": 1, "settled_at": 2])
        let pending = WalletTransaction(nip47: ["type": "outgoing", "amount": 1000, "created_at": 1])
        XCTAssertEqual(settled?.state, .settled)
        XCTAssertEqual(pending?.state, .pending)
    }

    func testUnusableEntriesAreDropped() {
        XCTAssertNil(WalletTransaction(nip47: ["amount": 1000, "created_at": 1]))
        XCTAssertNil(WalletTransaction(nip47: ["type": "sideways", "amount": 1000, "created_at": 1]))
        XCTAssertNil(WalletTransaction(nip47: ["type": "incoming", "amount": 1000]))
    }

    func testEmptyDescriptionIsNil() {
        XCTAssertNil(WalletTransaction(nip47: ["type": "incoming", "created_at": 1, "description": "   "])?.description)
    }

    func testMergeDedupesAndSortsNewestFirst() {
        func tx(_ id: String, _ t: TimeInterval) -> WalletTransaction {
            WalletTransaction(id: id, direction: .incoming, state: .settled, amountSats: 1, feeSats: 0,
                              description: nil, createdAt: Date(timeIntervalSince1970: t), settledAt: nil)
        }
        let merged = WalletTransaction.merge([tx("a", 30), tx("b", 20)], [tx("b", 20), tx("c", 25), tx("d", 10)])
        XCTAssertEqual(merged.map(\.id), ["a", "c", "b", "d"])
    }
}

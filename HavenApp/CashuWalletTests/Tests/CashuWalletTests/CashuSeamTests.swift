import XCTest
@testable import CashuWallet

/// The engine-free parts: reply decoding, the mint order, the per-account choice.
final class CashuSeamTests: XCTestCase {
    func testReplyResult() throws {
        let data = try CashuBridge.reply(Data(#"{"ok":true,"result":{"total":5,"reserved":0,"in_flight":0,"warn":false}}"#.utf8))
        let b = try JSONDecoder().decode(CashuBalance.self, from: data)
        XCTAssertEqual(b.total, 5)
        XCTAssertNil(b.perMint)
        XCTAssertEqual(try CashuBridge.reply(Data(#"{"ok":true}"#.utf8)), Data("null".utf8))
        XCTAssertEqual(try JSONDecoder().decode(UInt64.self, from: CashuBridge.reply(Data(#"{"ok":true,"result":42}"#.utf8))), 42)
    }

    func testReplyErrorCarriesCode() {
        XCTAssertThrowsError(try CashuBridge.reply(Data(#"{"ok":false,"error":"wallet: x","code":"pending"}"#.utf8))) {
            let e = $0 as? CashuError
            XCTAssertEqual(e?.code, "pending")
            XCTAssertEqual(e?.message, "wallet: x")
            XCTAssertEqual(e?.mayStillSettle, true)
        }
        XCTAssertThrowsError(try CashuBridge.reply(Data("not json".utf8))) {
            XCTAssertEqual(($0 as? CashuError)?.code, "error")
        }
    }

    func testPayOrderBiggestFirstSkipsEmpty() {
        let b = CashuBalance(total: 30, perMint: ["https://b": 10, "https://a": 10, "https://c": 20, "https://z": 0],
                             reserved: 0, inFlight: 0, warn: false)
        XCTAssertEqual(CashuWalletService.payOrder(b).map(\.mint), ["https://c", "https://a", "https://b"])
    }

    func testOnlyPreSpendRefusalsTryAnotherMint() {
        for code in ["not_enough", "busy", "no_change", "unknown_mint"] {
            XCTAssertTrue(CashuWalletService.triesNextMint(code), code)
        }
        for code in ["pending", "error", "already_spent", "not_paid"] {
            XCTAssertFalse(CashuWalletService.triesNextMint(code), code)
        }
    }

    func testPayZapsWithDefaultsToNWCPerAccount() throws {
        let suite = "cashu-seam-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        XCTAssertEqual(PayZapsWith.choice(accountHex: a, defaults: d), .nwc)
        XCTAssertNil(PayZapsWith.stored(accountHex: a, defaults: d))
        PayZapsWith.set(.cashu, accountHex: a.uppercased(), defaults: d)
        XCTAssertEqual(PayZapsWith.choice(accountHex: a, defaults: d), .cashu)
        XCTAssertEqual(PayZapsWith.choice(accountHex: b, defaults: d), .nwc)
        d.set("lightning-bank", forKey: PayZapsWith.key(accountHex: b))
        XCTAssertEqual(PayZapsWith.choice(accountHex: b, defaults: d), .nwc)
        PayZapsWith.clear(accountHex: a, defaults: d)
        XCTAssertEqual(PayZapsWith.choice(accountHex: a, defaults: d), .nwc)
        PayZapsWith.set(.cashu, accountHex: "", defaults: d)
        XCTAssertEqual(PayZapsWith.choice(accountHex: "", defaults: d), .nwc)
    }
}

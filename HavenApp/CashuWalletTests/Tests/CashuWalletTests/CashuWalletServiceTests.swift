import XCTest
@testable import CashuWallet

/// Against the real engine (libhaven.a) and the local test mint
/// (haven-go/wallet/swift_harness_test.go). scripts/cashu-swift-test.sh sets
/// CASHU_SWIFT_HARNESS to the file holding the mint and control URLs.
final class CashuWalletServiceTests: XCTestCase {
    struct Harness: Decodable { let mint: String; let control: String }

    private var harness: Harness!
    private var base: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CASHU_SWIFT_HARNESS"],
              let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("no test mint: run scripts/cashu-swift-test.sh")
        }
        harness = try JSONDecoder().decode(Harness.self, from: data)
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cashu-swift-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func control(_ path: String) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: harness.control + path)!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200, path)
        return String(decoding: data, as: UTF8.self)
    }

    private static func newAccount() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// A wallet with `sats` minted at the test mint.
    private func funded(_ sats: UInt64) async throws -> CashuWalletService {
        let w = try CashuWalletService.wallet(accountHex: Self.newAccount(), create: true, base: base)
        let info = try await w.addMint(harness.mint)
        XCTAssertTrue(info.sat)
        let quote = try await w.requestMint(mint: harness.mint, amount: sats)
        do {
            _ = try await w.claimMint(quote: quote.id)
            XCTFail("claimed an unpaid quote")
        } catch let e as CashuError {
            XCTAssertEqual(e.code, "not_paid")
        }
        _ = try await control("/pay?quote=\(quote.id)")
        let got = try await w.claimMint(quote: quote.id)
        XCTAssertEqual(got, sats)
        return w
    }

    func testPayInvoiceMeltsAndKeepsChange() async throws {
        let w = try await funded(100)
        let invoice = try await control("/invoice?amount=30")
        let paid = try await w.payInvoice(bolt11: invoice)
        XCTAssertGreaterThanOrEqual(paid.spent, 30)
        let after = try await w.balance()
        // 30 to the invoice, 1 the Lightning fee; the rest of the 4 sat
        // reserve comes back as change.
        XCTAssertEqual(after.total, 69)
        XCTAssertEqual(after.perMint?[harness.mint], 69)
        XCTAssertEqual(paid.spent - paid.change, 31)
    }

    func testNotEnoughSpendsNothing() async throws {
        let w = try await funded(50)
        let invoice = try await control("/invoice?amount=48") // 48 + 4 reserve > 50
        do {
            _ = try await w.payInvoice(bolt11: invoice)
            XCTFail("paid past the balance")
        } catch let e as CashuError {
            XCTAssertEqual(e.code, "not_enough")
            XCTAssertFalse(e.mayStillSettle)
        }
        let after = try await w.balance()
        XCTAssertEqual(after.total, 50)
    }

    func testPendingMeltMayStillSettle() async throws {
        let w = try await funded(100)
        _ = try await control("/melt-pending?on=1")
        defer { Task { _ = try? await self.control("/melt-pending?on=0") } }
        let invoice = try await control("/invoice?amount=10")
        do {
            _ = try await w.payInvoice(bolt11: invoice)
            XCTFail("a pending melt came back paid")
        } catch let e as CashuError {
            XCTAssertEqual(e.code, "pending")
            XCTAssertTrue(e.mayStillSettle)
        }
        // The inputs stay out of the balance while the mint decides.
        let after = try await w.balance()
        XCTAssertLessThan(after.total, 100)
        let open = try await w.pendingCount()
        XCTAssertEqual(open, 1)
        // A retry of the same invoice, or any other, waits for that one to settle.
        do {
            _ = try await w.payInvoice(bolt11: invoice)
            XCTFail("paid again while the first melt was pending")
        } catch let e as CashuError {
            XCTAssertEqual(e.code, "busy")
        }
        let second = try await control("/invoice?amount=5")
        do {
            _ = try await w.payInvoice(bolt11: second)
            XCTFail("a new payment went out while a melt was pending")
        } catch let e as CashuError {
            XCTAssertEqual(e.code, "busy")
        }
        let still = try await w.pendingCount()
        XCTAssertEqual(still, 1)
        _ = try await control("/melt-pending?on=0")
    }

    func testEmptyWalletRefuses() async throws {
        let w = try CashuWalletService.wallet(accountHex: Self.newAccount(), create: true, base: base)
        _ = try await w.addMint(harness.mint)
        let invoice = try await control("/invoice?amount=5")
        do {
            _ = try await w.payInvoice(bolt11: invoice)
            XCTFail("paid from nothing")
        } catch let e as CashuError {
            XCTAssertEqual(e, .notEnough)
        }
    }

    func testPayingNeverCreatesAWallet() throws {
        let account = Self.newAccount()
        XCTAssertThrowsError(try CashuWalletService.wallet(accountHex: account, base: base)) {
            XCTAssertEqual($0 as? CashuError, .noWallet)
        }
        XCTAssertFalse(CashuWalletService.exists(accountHex: account, base: base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CashuWalletService.fileURL(accountHex: account, base: base).path))
        XCTAssertThrowsError(try CashuWalletService.wallet(accountHex: "npub1notahex", create: true, base: base))
    }

    func testSameAccountSameWallet() async throws {
        let w = try await funded(21)
        let again = try CashuWalletService.wallet(accountHex: w.accountHex.uppercased(), base: base)
        XCTAssertTrue(w === again)
        XCTAssertTrue(CashuWalletService.exists(accountHex: w.accountHex, base: base))
    }
}

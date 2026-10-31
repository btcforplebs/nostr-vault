import XCTest
@testable import MediaLogic

final class VaultAccountChipsTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)
    private let cat = String(repeating: "c", count: 64)

    private func line(_ id: String, at: Int64) -> VaultActivity {
        VaultActivity(id: id, kind: .reply, actors: ["x"], createdAt: at, openId: id, preview: "")
    }

    func testOneAccountShowsNoChips() {
        XCTAssertEqual(VaultAccountChips.chips(accounts: [me], active: me), [])
        XCTAssertEqual(VaultAccountChips.chips(accounts: [me, me.uppercased()], active: me), [])
        XCTAssertEqual(VaultAccountChips.resolve(.all, accounts: [me], active: me), .account(me))
    }

    func testChipsLeadWithAllThenActiveAccount() {
        XCTAssertEqual(VaultAccountChips.chips(accounts: [me, bob, cat], active: bob),
                       [.all, .account(bob), .account(me), .account(cat)])
    }

    func testDefaultIsActiveAccount() {
        let accounts = [me, bob]
        XCTAssertEqual(VaultAccountChips.resolve(nil, accounts: accounts, active: me), .account(me))
        XCTAssertTrue(VaultAccountChips.isDefault(.account(me), active: me))
        XCTAssertFalse(VaultAccountChips.isDefault(.all, active: me))
        XCTAssertFalse(VaultAccountChips.isDefault(.account(bob), active: me))
    }

    func testRemovedAccountFallsBackToActive() {
        XCTAssertEqual(VaultAccountChips.resolve(.account(cat), accounts: [me, bob], active: me), .account(me))
        XCTAssertEqual(VaultAccountChips.resolve(.account(bob), accounts: [me, bob], active: me), .account(bob))
    }

    func testChipAccounts() {
        XCTAssertEqual(VaultAccountChips.accounts(for: .all, accounts: [me, bob, me]), [me, bob])
        XCTAssertEqual(VaultAccountChips.accounts(for: .account(bob.uppercased()), accounts: [me, bob]), [bob])
    }

    func testMergeInterleavesNewestFirstAndKeepsAccount() {
        let merged = VaultAccountChips.merge(
            [me: [line("m1", at: 300), line("m2", at: 100)], bob: [line("b1", at: 200)]],
            order: [me, bob], limit: 10)
        XCTAssertEqual(merged.map(\.line.id), ["m1", "b1", "m2"])
        XCTAssertEqual(merged.map(\.account), [me, bob, me])
    }

    func testSameLineIdInTwoAccountsStaysTwoRows() {
        let merged = VaultAccountChips.merge(
            [me: [line("follow-2026-10-31", at: 100)], bob: [line("follow-2026-10-31", at: 100)]],
            order: [me, bob], limit: 10)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        // A tie goes to the account first in order, every time.
        XCTAssertEqual(merged.map(\.account), [me, bob])
    }

    func testTieGoesToAccountOrderBeforeId() {
        let merged = VaultAccountChips.merge(
            [bob: [line("a", at: 100)], me: [line("z", at: 100)]],
            order: [me, bob], limit: 10)
        XCTAssertEqual(merged.map(\.account), [me, bob])
    }

    func testMergeCapsAtLimit() {
        let merged = VaultAccountChips.merge(
            [me: [line("1", at: 5), line("2", at: 4)], bob: [line("3", at: 3)]],
            order: [me, bob], limit: 2)
        XCTAssertEqual(merged.map(\.line.id), ["1", "2"])
    }
}

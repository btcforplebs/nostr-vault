import XCTest
@testable import MediaLogic

/// Vault search's Notes / My notes switch (search plan A2, Logen dc9ea221 + 5d1ce4cb).
final class VaultSearchScopeTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)

    func testNotesAsksForEveryone() {
        XCTAssertNil(VaultSearchScope.all.authors(me: me))
        XCTAssertTrue(VaultSearchScope.all.keepsNote(pubkey: other, me: me))
        XCTAssertTrue(VaultSearchScope.all.showsPeople)
    }

    /// Only the account in use, not every added account.
    func testMyNotesAsksForTheAccountInUse() {
        XCTAssertEqual(VaultSearchScope.mine.authors(me: me.uppercased()), [me])
        XCTAssertTrue(VaultSearchScope.mine.keepsNote(pubkey: me, me: me))
        XCTAssertTrue(VaultSearchScope.mine.keepsNote(pubkey: me.uppercased(), me: me))
        XCTAssertFalse(VaultSearchScope.mine.keepsNote(pubkey: other, me: me))
        XCTAssertFalse(VaultSearchScope.mine.showsPeople)
    }

    /// No account must never widen My notes to everyone.
    func testMyNotesWithNoAccountFindsNothing() {
        XCTAssertEqual(VaultSearchScope.mine.authors(me: ""), [])
        XCTAssertFalse(VaultSearchScope.mine.keepsNote(pubkey: other, me: ""))
        XCTAssertFalse(VaultSearchScope.mine.keepsNote(pubkey: "", me: ""))
    }

    func testTheSwitchRemembersItsSetting() {
        XCTAssertEqual(VaultSearchScope.saved("mine"), .mine)
        XCTAssertEqual(VaultSearchScope.saved("all"), .all)
        XCTAssertEqual(VaultSearchScope.saved(nil), .all)
        XCTAssertEqual(VaultSearchScope.saved("junk"), .all)
        XCTAssertEqual(VaultSearchScope.allCases.map(\.title), ["Notes", "My notes"])
    }

    // MARK: The walk's filter

    func testPageFilterCarriesAuthorsOnlyWhenGiven() {
        let open = LocalRelaySearchPlan.pageFilter(kind: 1, until: nil, authors: nil)
        XCTAssertNil(open["authors"])
        XCTAssertNil(open["until"])
        XCTAssertEqual(open["kinds"] as? [Int], [1])
        XCTAssertEqual(open["limit"] as? Int, LocalRelaySearchPlan.pageLimit)

        let mine = LocalRelaySearchPlan.pageFilter(kind: 30023, until: 1_700_000_000, authors: [me])
        XCTAssertEqual(mine["authors"] as? [String], [me])
        XCTAssertEqual(mine["until"] as? Int64, 1_700_000_000)
        XCTAssertEqual(mine["kinds"] as? [Int], [30023])
    }

    // MARK: Flipping the switch

    /// The same query with the other scope runs again; it is not kept.
    func testFlippingRunsTheSameQueryAgain() {
        var state = VaultSearchLogic.QueryState()
        XCTAssertEqual(state.typed("bitcoin"), .run("bitcoin"))
        XCTAssertTrue(state.started("bitcoin"))
        XCTAssertTrue(state.landed("bitcoin", as: .done))
        XCTAssertEqual(state.typed("bitcoin"), .keep)

        state.forgetResults()
        XCTAssertEqual(state.status, .searching)
        XCTAssertEqual(state.resultsQuery, "")
        XCTAssertEqual(state.typed("bitcoin"), .run("bitcoin"))
    }

    func testFlippingWithNothingTypedStaysIdle() {
        var state = VaultSearchLogic.QueryState()
        _ = state.typed("b")
        state.forgetResults()
        XCTAssertEqual(state.status, .idle)
    }
}

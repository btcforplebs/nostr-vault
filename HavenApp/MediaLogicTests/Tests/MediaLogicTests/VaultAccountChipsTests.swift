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
        let follows = VaultActivity(id: "follow-2026-10-31", kind: .follow, actors: ["x"], createdAt: 100, openId: nil, preview: "")
        let merged = VaultAccountChips.merge(
            [me: [follows], bob: [follows]],
            order: [me, bob], limit: 10)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        // A tie goes to the account first in order, every time.
        XCTAssertEqual(merged.map(\.account), [me, bob])
    }

    func testOneEventForSeveralAccountsIsOneRowInSwitcherOrder() {
        let reply = line(String(repeating: "e", count: 64), at: 200)
        let merged = VaultAccountChips.merge(
            [cat: [reply], bob: [reply, line("b1", at: 100)], me: [reply]],
            order: [me, bob, cat], limit: 10)
        XCTAssertEqual(merged.map(\.line.id), [reply.id, "b1"])
        XCTAssertEqual(merged[0].accounts, [me, bob, cat])
        XCTAssertEqual(merged[0].account, me)
        XCTAssertEqual(merged[0].id, reply.id)
        XCTAssertEqual(merged[1].accounts, [bob])
    }

    func testFoldedLinesStayOneRowPerAccount() {
        for kind in [VaultActivity.Kind.reaction, .repost, .follow] {
            let folded = VaultActivity(id: "reaction-p1", kind: kind, actors: ["x"], createdAt: 100, openId: "p1", preview: "")
            let merged = VaultAccountChips.merge([me: [folded], bob: [folded]], order: [me, bob], limit: 10)
            XCTAssertEqual(merged.map(\.accounts), [[me], [bob]], "\(kind)")
        }
        let zapFold = VaultActivity(id: "zap-p1", kind: .zap, actors: ["x"], createdAt: 100, openId: "p1", preview: "")
        XCTAssertFalse(VaultAccountChips.isOneEvent(zapFold))
        let zapWithWords = VaultActivity(id: "z1", kind: .zap, actors: ["x"], createdAt: 100, openId: nil, preview: "gm")
        XCTAssertTrue(VaultAccountChips.isOneEvent(zapWithWords))
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

    func testSwitchTargetOnlyForAnotherHeldAccount() {
        let npubs = [me: "npub1me", bob: "npub1bob"]
        // Another account's line: switch to it, whatever the case of the hex.
        XCTAssertEqual(VaultAccountChips.switchTarget(lineAccount: bob.uppercased(), active: me, npubByHex: npubs), "npub1bob")
        // The active account's own line, or a list with one account: no switch.
        XCTAssertNil(VaultAccountChips.switchTarget(lineAccount: me, active: me.uppercased(), npubByHex: npubs))
        XCTAssertNil(VaultAccountChips.switchTarget(lineAccount: nil, active: me, npubByHex: npubs))
        // An account the device no longer holds: nothing to switch to.
        XCTAssertNil(VaultAccountChips.switchTarget(lineAccount: cat, active: me, npubByHex: npubs))
    }

    /// Sweep 11-01 #3b: another account's list stopped at its first read.
    /// Load more raises the limit while a filter came back full, up to the
    /// relay's MaxLimit (above it the relay answers MaxLimit/4).
    func testOtherAccountLoadMoreRaisesTheLimitToTheRelayCap() {
        XCTAssertEqual(VaultAccountChips.nextOtherAccountLimit(current: 300, readFull: true), 600)
        XCTAssertEqual(VaultAccountChips.nextOtherAccountLimit(current: 900, readFull: true), 1000)
        XCTAssertNil(VaultAccountChips.nextOtherAccountLimit(current: 1000, readFull: true))
        XCTAssertNil(VaultAccountChips.nextOtherAccountLimit(current: 300, readFull: false))
    }

    // MARK: - Every page filters (Logen 11-02: chips filter, a post tap switches)

    func testEveryPageButMediaShowsTheChips() {
        for page in [VaultAccountPage.activity, .notes, .likes, .zaps, .followers] {
            XCTAssertTrue(VaultAccountChips.pageShowsChips(page), "\(page)")
        }
        XCTAssertFalse(VaultAccountChips.pageShowsChips(.media))
        XCTAssertFalse(VaultAccountChips.pageShowsChips(.bookmarks), "the active account's list only")
        XCTAssertFalse(VaultAccountChips.pageShowsChips(.messages), "the active account's inbox only")
    }

    func testGivenTargetsAreTheAccountsOwnLikesAndZaps() {
        let events: [(pubkey: String, kind: Int, tags: [[String]])] = [
            ("BB", 7, [["e", "liked"], ["p", "x"]]),           // bb's like
            ("cc", 7, [["e", "notMine"]]),                      // someone else's like
            ("wallet", 9735, [["P", "bb"], ["e", "zapped"]]),   // a zap bb sent
            ("wallet", 9735, [["P", "cc"], ["e", "theirs"]]),   // a zap cc sent
            ("bb", 1, [["e", "reply"]]),                        // a reply is not a like
        ]
        XCTAssertEqual(VaultAccountChips.givenTargets(events, account: "bb"), ["liked", "zapped"])
    }

    func testAPostBelongsToItsAuthorThenTheTaggedThenTheGiver() {
        let owners: Set<String> = ["aa", "bb"]
        // The active account's own: nil, it opens as is.
        XCTAssertNil(VaultAccountChips.pageAccount(author: "aa", tags: [], giver: nil, owners: owners, active: "aa"))
        XCTAssertEqual(VaultAccountChips.pageAccount(author: "BB", tags: [], giver: nil, owners: owners, active: "aa"), "bb")
        // Someone else's post tagging bb.
        XCTAssertEqual(VaultAccountChips.pageAccount(author: "zz", tags: [["p", "x"], ["p", "bb"]], giver: nil, owners: owners, active: "aa"), "bb")
        // A post bb liked (My Likes), tagging no one of ours.
        XCTAssertEqual(VaultAccountChips.pageAccount(author: "zz", tags: [], giver: "bb", owners: owners, active: "aa"), "bb")
        XCTAssertNil(VaultAccountChips.pageAccount(author: "zz", tags: [], giver: nil, owners: owners, active: "aa"))
    }

    func testFollowersMergeOncePerPersonWatchedFirst() {
        typealias F = (pubkey: String, isNews: Bool, followedAt: Int64, listAt: Int64)
        let a: [F] = [("x", true, 50, 0), ("old1", false, 0, 10)]
        let b: [F] = [("y", true, 90, 0), ("x", true, 20, 0), ("old2", false, 0, 30)]
        let merged = VaultAccountChips.mergeFollowers([a, b], id: { $0.pubkey }, isNews: { $0.isNews },
                                                      followedAt: { $0.followedAt }, listAt: { $0.listAt })
        XCTAssertEqual(merged.map(\.pubkey), ["y", "x", "old2", "old1"])
    }

    // MARK: - No flash on a pick (Logen 11-02)

    func testAPickWaitsOnlyForAnotherAccountNotReadYet() {
        let accounts = ["aa", "bb", "cc"]
        // The active account's own list is always there.
        XCTAssertFalse(VaultAccountChips.needsRead(.account("aa"), accounts: accounts, active: "AA", loaded: []))
        // Another account not read yet: wait, keep the list on screen.
        XCTAssertTrue(VaultAccountChips.needsRead(.account("bb"), accounts: accounts, active: "aa", loaded: []))
        XCTAssertFalse(VaultAccountChips.needsRead(.account("bb"), accounts: accounts, active: "aa", loaded: ["bb"]))
        // All waits until every other account is read.
        XCTAssertTrue(VaultAccountChips.needsRead(.all, accounts: accounts, active: "aa", loaded: ["bb"]))
        XCTAssertFalse(VaultAccountChips.needsRead(.all, accounts: accounts, active: "aa", loaded: ["bb", "cc"]))
    }
}

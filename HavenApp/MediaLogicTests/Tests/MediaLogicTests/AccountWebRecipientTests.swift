import XCTest
@testable import MediaLogic

/// Another account's alerts, switcher badge and Vault rows are judged by that
/// account's web, not the open account's (Android 2012 Tron must-fix 2, the
/// Apple twin of `FeedService.trustedPubkeysFor`).
final class AccountWebRecipientTests: XCTestCase {
    private let open: Set<String> = ["me", "f1"]
    private let pooled: Set<String> = ["me", "f1", "other", "g1", "g1-friend"]

    func testOpenAccountGetsItsOwnWeb() {
        XCTAssertEqual(AccountWeb.trusted(forRecipient: "me", active: "me", open: { self.open }, pooled: pooled), open)
        XCTAssertEqual(AccountWeb.trusted(forRecipient: "ME", active: "me", open: { self.open }, pooled: pooled), open,
                       "hex case does not make the open account another account")
        XCTAssertEqual(AccountWeb.trusted(forRecipient: "", active: "me", open: { self.open }, pooled: pooled), open,
                       "no recipient: the open account")
    }

    func testOtherAccountGetsThePooledWebNotTheOpenAccounts() {
        let web = AccountWeb.trusted(forRecipient: "other", active: "me", open: { self.open }, pooled: pooled)
        XCTAssertEqual(web, pooled)
        XCTAssertTrue(web.contains("g1-friend"), "someone in the other account's web may reach it")
    }

    func testOtherAccountDoesNotBuildTheOpenWeb() {
        var built = false
        _ = AccountWeb.trusted(forRecipient: "other", active: "me", open: { built = true; return self.open },
                               pooled: pooled)
        XCTAssertFalse(built)
    }

    func testMemoSaysWhetherItHasLinks() {
        let memo = TrustedWebMemo()
        XCTAssertFalse(memo.hasLinks)
        memo.load(depth: 3)
        XCTAssertFalse(memo.hasLinks)
        memo.load(links: TrustLinksIndex(follows: ["f1"], links: ["x": [0]]), depth: 3)
        XCTAssertTrue(memo.hasLinks)
        memo.load(links: nil)
        XCTAssertFalse(memo.hasLinks)
    }

    /// The call sites that judge a recipient other than the open account, and
    /// Tron's 2011 re-review should-fix (first links read) and low (disk snapshot).
    func testWiring() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp")
        func src(_ path: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
        }
        for path in ["Services/LocalNotificationService.swift", "Services/AccountUnreadStore+ListRules.swift",
                     "Views/Vault/VaultAccountScope.swift"] {
            let code = try src(path)
            XCTAssertTrue(code.contains("trustedPubkeys(for:"), "\(path) judges each recipient by its own web")
        }
        let notify = try src("Services/LocalNotificationService.swift")
        XCTAssertTrue(notify.contains("trustedPubkeys(for: recipientHex)"))
        let wot = try src("Services/Feed/FeedService+WebOfTrust.swift")
        XCTAssertTrue(wot.contains("readLinks: firstLinks"), "the first read parses the links before anyone paints")
        XCTAssertTrue(wot.contains("accountFollowsRestored"), "follows from a disk snapshot count as the account's own")
        let snaps = try src("Services/Feed/FeedService+Snapshots.swift")
        XCTAssertTrue(snaps.contains("accountFollowsRestored = !followedPubkeys.isEmpty"))
        XCTAssertTrue(snaps.contains("accountFollowsRestored = false"))
    }
}

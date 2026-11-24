import XCTest
@testable import MediaLogic

/// Each account has its own Follow Distance and Minimum Followers.
final class AccountReachTests: XCTestCase {
    private let owner = "npub1owner", alt = "npub1alt", third = "npub1third"

    private func config() -> HavenConfig {
        var c = HavenConfig()
        c.ownerNpub = owner
        c.whitelistedNpubs = [alt, third]
        c.chatRelayWotDepth = 3
        c.chatRelayMinFollowers = 3
        return c
    }

    /// Nothing to convert: before anyone changes anything, every account
    /// runs on the value the device already had.
    func testEveryAccountStartsOnTheOldSingleValue() {
        let c = config()
        for npub in [owner, alt, third, ""] {
            XCTAssertEqual(c.reach(for: npub), AccountReach(depth: 3, minFollowers: 3), npub)
        }
        XCTAssertTrue(c.relayAccountReach.isEmpty, "no entry is written until an account gets its own")
    }

    func testChangingOneAccountLeavesTheOthersAlone() {
        var c = config()
        c.setReach(AccountReach(depth: 1, minFollowers: 0), for: alt)
        XCTAssertEqual(c.reach(for: alt), AccountReach(depth: 1, minFollowers: 0))
        XCTAssertEqual(c.reach(for: owner), AccountReach(depth: 3, minFollowers: 3))
        XCTAssertEqual(c.reach(for: third), AccountReach(depth: 3, minFollowers: 3))
        XCTAssertEqual(c.chatRelayWotDepth, 3, "the first account's stored value did not move")
        XCTAssertEqual(c.relayAccountReach, [alt: AccountReach(depth: 1, minFollowers: 0)])
    }

    /// The first account's value is the old stored pair, which other
    /// accounts with no entry also read. Changing it must not move them.
    func testChangingTheFirstAccountLeavesTheOthersAlone() {
        var c = config()
        c.setReach(AccountReach(depth: 2, minFollowers: 3), for: alt)
        c.setReach(AccountReach(depth: 1, minFollowers: 7), for: owner)
        XCTAssertEqual(c.reach(for: owner), AccountReach(depth: 1, minFollowers: 7))
        XCTAssertEqual(c.chatRelayWotDepth, 1)
        XCTAssertEqual(c.chatRelayMinFollowers, 7)
        XCTAssertEqual(c.reach(for: alt), AccountReach(depth: 2, minFollowers: 3), "alt keeps the value it chose")
        XCTAssertEqual(c.reach(for: third), AccountReach(depth: 3, minFollowers: 3),
                       "third had no entry and must keep the value it ran on")
    }

    func testTheScreenShowsTheAccountYouAreOn() {
        var c = config()
        c.setReach(AccountReach(depth: 1, minFollowers: 0), for: alt)
        XCTAssertEqual(c.reachAccountNpub, owner, "no account picked means the first")
        XCTAssertEqual(c.reach(for: c.reachAccountNpub).depth, 3)
        c.activeAccountNpub = alt
        XCTAssertEqual(c.reach(for: c.reachAccountNpub).depth, 1)
    }

    func testValuesAreHeldToWhatTheScreenOffers() {
        var c = config()
        c.setReach(AccountReach(depth: 9, minFollowers: 500), for: alt)
        XCTAssertEqual(c.reach(for: alt), AccountReach(depth: 3, minFollowers: 100))
        c.setReach(AccountReach(depth: 0, minFollowers: -4), for: alt)
        XCTAssertEqual(c.reach(for: alt), AccountReach(depth: 1, minFollowers: 0),
                       "level 0 is a public relay and is never an account's level")
    }

    func testRemovingAnAccountDropsItsValue() {
        var c = config()
        c.setReach(AccountReach(depth: 1, minFollowers: 0), for: alt)
        c.removeAccountEntries(npub: alt)
        XCTAssertNil(c.reachPerAccount[alt])
        XCTAssertTrue(c.relayAccountReach.isEmpty)
        // An entry left behind for an account no longer here is not sent.
        c.reachPerAccount["npub1gone"] = AccountReach(depth: 1, minFollowers: 0)
        XCTAssertTrue(c.relayAccountReach.isEmpty)
    }

    func testSavedConfigKeepsEachAccountsValueAndAnOlderFileStillOpens() throws {
        var c = config()
        c.setReach(AccountReach(depth: 2, minFollowers: 5), for: alt)
        let back = try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.reach(for: alt), AccountReach(depth: 2, minFollowers: 5))

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        json.removeValue(forKey: "reachPerAccount")
        let older = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(older.reachPerAccount.isEmpty)
        XCTAssertEqual(older.reach(for: alt), AccountReach(depth: 3, minFollowers: 3))
    }

    /// What the relay is handed: the file it reads, named in its
    /// environment, in the shape haven-go/account_reach.go parses. The first
    /// account stays WOT_DEPTH.
    func testTheRelayIsHandedEachAccountsValue() throws {
        var c = config()
        c.setReach(AccountReach(depth: 2, minFollowers: 5), for: alt)
        c.setReach(AccountReach(depth: 1, minFollowers: 3), for: owner)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputs = RelayConfiguration.launchInputs(config: c, relayDataDir: dir)
        XCTAssertEqual(inputs.env["ACCOUNT_REACH_FILE"], HavenConfig.accountReachFile)
        XCTAssertEqual(inputs.env["WOT_DEPTH"], "1")
        XCTAssertEqual(inputs.env["WOT_MINIMUM_FOLLOWERS"], "3")
        HavenConfig.writeAccountReachFile(inputs.accountReach, under: dir)

        let data = try Data(contentsOf: dir.appendingPathComponent("account_reach.json"))
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(file["v"] as? Int, 1)
        let accounts = try XCTUnwrap(file["accounts"] as? [String: [String: Int]])
        XCTAssertEqual(accounts, [alt: ["depth": 2, "min_followers": 5],
                                  third: ["depth": 3, "min_followers": 3]])

        // A change to one account's value is a change to what the relay
        // starts with, so the app restarts it.
        var changed = c
        changed.setReach(AccountReach(depth: 3, minFollowers: 5), for: alt)
        XCTAssertNotEqual(RelayConfiguration.launchInputs(config: changed, relayDataDir: dir), inputs)
    }

    /// The names the relay reads, from its own source.
    func testTheFileMatchesWhatTheRelayReads() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let go = try String(contentsOf: repo.appendingPathComponent("haven-go/account_reach.go"), encoding: .utf8)
        let conf = try String(contentsOf: repo.appendingPathComponent("haven-go/config.go"), encoding: .utf8)
        for name in ["`json:\"v\"`", "`json:\"accounts\"`", "`json:\"depth\"`", "`json:\"min_followers\"`"] {
            XCTAssertTrue(go.contains(name), "haven-go no longer reads \(name)")
        }
        XCTAssertTrue(conf.contains("getEnvString(\"ACCOUNT_REACH_FILE\""))
    }

    /// Settings copied from another of your devices carry the first
    /// account's level; the other accounts keep theirs.
    func testCopiedSettingsMoveOnlyTheFirstAccount() {
        var c = config()
        c.setReach(AccountReach(depth: 2, minFollowers: 3), for: alt)
        let applied = CopySettings.apply(["wot_depth": 1], to: c)
        XCTAssertEqual(applied.reach(for: owner).depth, 1)
        XCTAssertEqual(applied.reach(for: alt).depth, 2)
        XCTAssertEqual(applied.reach(for: third).depth, 3)
    }
}

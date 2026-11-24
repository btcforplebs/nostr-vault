import XCTest
@testable import MediaLogic

/// Desktop Vaults (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.5, §3). Reads the shared
/// fixtures in docs/fixtures/desktop-vaults straight from the repo, the same
/// files Android's DesktopVaultsRules and the web box tests read.
final class DesktopVaultsTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures/desktop-vaults")

    static func fixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name + ".json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }

    static func list(_ value: Any?) throws -> DesktopVaultList {
        try XCTUnwrap(DesktopVaultList(rawValue: try XCTUnwrap(value as? Int)))
    }

    // MARK: lists.json (§2.5 rules 1-6)

    func testListRulesFixture() throws {
        let doc = try Self.fixture("lists")
        let named = try Self.decode([String: DesktopVault].self, try XCTUnwrap(doc["vaults"]))
        let vaults = Array(named.values)
        let keyOf: (DesktopVault?) -> String? = { vault in named.first { $0.value.id == vault?.id }?.key }
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 40)
        var ran = 0
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let vault = (c["vault"] as? String).flatMap { named[$0] }
            let path = (c["path"] as? String).flatMap(DesktopVaultPath.init(rawValue:))
            let tags = c["tags"] as? [[String]]
            switch c["op"] as? String {
            case "owner":
                let owner = DesktopVaultsLists.owner(of: try XCTUnwrap(c["tag"] as? [String]),
                                                     in: try Self.list(c["list"]), vaults: vaults)
                XCTAssertEqual(keyOf(owner), expect["owner"] as? String, name)
            case "on", "off":
                let list = try Self.list(c["list"])
                let v = try XCTUnwrap(vault, name), p = try XCTUnwrap(path, name), t = try XCTUnwrap(tags, name)
                let change = c["op"] as? String == "on"
                    ? DesktopVaultsLists.turningOn(v, path: p, in: list, tags: t, vaults: vaults)
                    : DesktopVaultsLists.turningOff(v, path: p, in: list, tags: t)
                XCTAssertEqual(change, try Self.expected(expect), name)
                if case .tags(let out) = change, c["op"] as? String == "on", out != t {
                    XCTAssertTrue(DesktopVaultsLists.isListed(v, path: p, in: list, tags: out), name)
                }
            case "remove":
                let raw = try XCTUnwrap(c["lists"] as? [String: [[String]]])
                var lists: [DesktopVaultList: [[String]]] = [:]
                for (k, v) in raw { lists[try XCTUnwrap(DesktopVaultList(rawValue: Int(k) ?? 0))] = v }
                let result = DesktopVaultsLists.removingVault(try XCTUnwrap(vault), from: lists)
                if let refused = expect["refused"] as? Int {
                    XCTAssertEqual(result, .failure(DesktopVaultListRefusal(list: try XCTUnwrap(DesktopVaultList(rawValue: refused)))), name)
                } else {
                    let changed = try XCTUnwrap(expect["changed"] as? [String: [[String]]])
                    var want: [DesktopVaultList: [[String]]] = [:]
                    for (k, v) in changed { want[try XCTUnwrap(DesktopVaultList(rawValue: Int(k) ?? 0))] = v }
                    XCTAssertEqual(result, .success(want), name)
                }
            case "reorder":
                XCTAssertEqual(DesktopVaultsLists.reordered(try XCTUnwrap(tags), in: try Self.list(c["list"]), vaults: vaults),
                               expect["tags"] as? [[String]], name)
            case "overGuidance":
                XCTAssertEqual(DesktopVaultsLists.overGuidance(try XCTUnwrap(tags), list: try Self.list(c["list"])),
                               expect["over"] as? Bool, name)
            case "hostTaken":
                let except = (c["except"] as? String).flatMap { named[$0]?.id }
                let taken = DesktopVaultsLists.hostTaken(try XCTUnwrap(c["url"] as? String), by: vaults, except: except)
                XCTAssertEqual(keyOf(taken), expect["owner"] as? String, name)
            default:
                XCTFail("unknown op in \(name)")
                continue
            }
            ran += 1
        }
        XCTAssertEqual(ran, cases.count)
    }

    static func expected(_ expect: [String: Any]) throws -> DesktopVaultListChange {
        if let refused = expect["refused"] as? Int {
            return .refused(try XCTUnwrap(DesktopVaultList(rawValue: refused)))
        }
        return .tags(try XCTUnwrap(expect["tags"] as? [[String]]))
    }

    // MARK: migration.json (§3)

    func testMigrationFixture() throws {
        let cases = try XCTUnwrap(try Self.fixture("migration")["migration"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let out = DesktopVaultsLogic.takingInSlot(
                try Self.decode([DesktopVault].self, try XCTUnwrap(c["vaults"])),
                slot: try XCTUnwrap(c["slot"] as? String),
                taken: c["taken"] as? String,
                devices: try Self.decode([MeshDevice].self, try XCTUnwrap(c["devices"])))
            XCTAssertEqual(out, try Self.decode([DesktopVault].self, try XCTUnwrap(c["expect"])), name)
        }
    }

    func testDerivedAddressesFixture() throws {
        let cases = try XCTUnwrap(try Self.fixture("migration")["derived"] as? [[String: Any]])
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let vaults = try Self.decode([DesktopVault].self, try XCTUnwrap(c["vaults"]))
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            XCTAssertEqual(DesktopVaultsLogic.wssURLs(vaults), expect["wss"] as? [String], name)
            XCTAssertEqual(DesktopVaultsLogic.httpsURLs(vaults), expect["https"] as? [String], name)
            XCTAssertEqual(DesktopVaultsLogic.envList(vaults, slot: try XCTUnwrap(c["slot"] as? String)),
                           expect["env"] as? String, name)
        }
    }

    /// The names haven-go's macSyncStatusFile gives (printed by the engine
    /// itself into the fixture), scheme kept and SHA-256 over 200 bytes.
    func testStatusFileNamesMatchTheEngine() throws {
        let rows = try XCTUnwrap(try Self.fixture("migration")["statusFiles"] as? [[String: String]])
        XCTAssertTrue(rows.contains { $0["file"]?.count == "mac_sync_status-".count + 64 + ".json".count })
        for row in rows {
            XCTAssertEqual(DesktopVaultsLogic.statusFileName(base: try XCTUnwrap(row["base"])), row["file"], row["base"] ?? "")
        }
    }

    // MARK: The config the app runs on

    /// A one-slot user gets exactly the relay lists they had: the Vault made
    /// from the slot stands where the slot stood, in every spelling.
    func testSlotUserKeepsTheirRelayLists() {
        for slot in ["wss://mac.example.com/", "https://Mac.Example.com", "ws://192.168.1.5:3355", "mac.example.com/haven"] {
            var config = HavenConfig()
            config.feedRelays = ["wss://relay.damus.io"]
            config.blastrRelays = ["wss://nos.lol"]
            config.blossomMirrors = ["https://blossom.primal.net"]
            config.macRelayURL = slot
            let wss = config.macRelayWssURL, https = config.macRelayHttpsURL
            config.takeInDesktopVaultSlot()
            XCTAssertEqual(config.desktopVaults.count, 1, slot)
            XCTAssertEqual(config.desktopVaultsSlot, slot)
            XCTAssertEqual(config.macRelayURL, slot, "the slot is never rewritten")
            XCTAssertEqual(config.activeFeedRelays, [wss, "wss://relay.damus.io"], slot)
            XCTAssertEqual(config.activeBlastrRelays, [wss, "wss://nos.lol"], slot)
            XCTAssertEqual(config.activeBlossomMirrors, ["https://blossom.primal.net", https], slot)
            XCTAssertEqual(DesktopVaultsLogic.envList(config.desktopVaultsInEffect, slot: config.macRelayURL), "", slot)
        }
    }

    func testEveryHTTPSVaultFeedsTheDerivedLists() {
        var config = HavenConfig()
        config.feedRelays = ["wss://relay.damus.io", "wss://b.example.com"]
        config.blossomMirrors = ["https://blossom.primal.net"]
        config.desktopVaultsSlot = ""
        config.desktopVaults = [
            DesktopVault(id: "b", name: "", httpsURL: "https://b.example.com", order: 1),
            DesktopVault(id: "c", name: "", meshNpub: "npub1" + String(repeating: "c", count: 58), order: 2),
            DesktopVault(id: "a", name: "", httpsURL: "https://a.example.com", order: 0),
        ]
        // b is already a feed relay and keeps its place, as the slot did.
        XCTAssertEqual(config.activeFeedRelays, ["wss://a.example.com", "wss://relay.damus.io", "wss://b.example.com"])
        XCTAssertEqual(config.activeBlossomMirrors, ["https://blossom.primal.net", "https://a.example.com", "https://b.example.com"])
        XCTAssertEqual(config.blossomDeleteTargets(ownerServerList: [], photoURL: nil, includeHomeVault: false),
                       ["https://blossom.primal.net"])
    }

    /// The old Desktop vault sync tab still edits the slot until P4; the
    /// lists follow before the next save.
    func testOldTabEditCountsBeforeSave() {
        var config = HavenConfig()
        config.feedRelays = []
        config.macRelayURL = "https://old.example.com"
        config.takeInDesktopVaultSlot()
        config.macRelayURL = "https://new.example.com"
        XCTAssertEqual(config.activeFeedRelays, ["wss://new.example.com"])
        config.macRelayURL = ""
        XCTAssertEqual(config.activeFeedRelays, [])
    }

    /// Tron M1: a path edit on the same host reaches the Vault, so the lists
    /// and MAC_RELAY_URL stay on one address.
    func testOldTabPathEditOnSameHost() {
        var config = HavenConfig()
        config.feedRelays = []
        config.blossomMirrors = []
        config.macRelayURL = "https://mac.example.com/haven"
        config.takeInDesktopVaultSlot()
        config.macRelayURL = "https://mac.example.com/relay"
        XCTAssertEqual(config.activeFeedRelays, [config.macRelayWssURL])
        XCTAssertEqual(config.activeFeedRelays, ["wss://mac.example.com/relay"])
        XCTAssertEqual(config.activeBlossomMirrors, ["https://mac.example.com/relay"])
        config.takeInDesktopVaultSlot()
        XCTAssertEqual(config.desktopVaults.map(\.httpsURL), ["https://mac.example.com/relay"])
        XCTAssertEqual(config.activeFeedRelays, ["wss://mac.example.com/relay"])
    }

    /// Tron S2: a switch adds the Vault's whole base, path included.
    func testEntryKeepsThePath() {
        let vault = DesktopVault(id: "h", name: "", httpsURL: "https://mac.example.com/haven", order: 0)
        XCTAssertEqual(DesktopVaultsLists.entry(for: vault, path: .web, in: .relays), ["r", "wss://mac.example.com/haven"])
        XCTAssertEqual(DesktopVaultsLists.entry(for: vault, path: .web, in: .inbox), ["relay", "wss://mac.example.com/haven/inbox"])
        XCTAssertEqual(DesktopVaultsLists.entry(for: vault, path: .web, in: .media), ["server", "https://mac.example.com/haven"])
        let tags = [["r", "wss://mac.example.com/haven"]]
        XCTAssertTrue(DesktopVaultsLists.isListed(vault, path: .web, in: .relays, tags: tags))
    }

    /// Tron S1: an unreadable list is migrated again from the slot.
    func testUnreadableListIsMigratedAgain() throws {
        var config = HavenConfig()
        config.macRelayURL = "https://mac.example.com"
        config.takeInDesktopVaultSlot()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json["desktopVaults"] = "not a list"
        var back = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.desktopVaults, [])
        XCTAssertNil(back.desktopVaultsSlot)
        back.takeInDesktopVaultSlot()
        XCTAssertEqual(back.desktopVaults.map(\.httpsURL), ["https://mac.example.com"])
    }

    func testConfigRoundTripAndUnknownVaultSkipped() throws {
        var config = HavenConfig()
        config.desktopVaults = [DesktopVault(id: "a", name: "Mac", kind: .box, httpsURL: "https://a.example.com", order: 0)]
        config.desktopVaultsSlot = ""
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        var stored = try XCTUnwrap(json["desktopVaults"] as? [[String: Any]])
        stored.append(["name": "no id"])
        stored.append(["id": "z", "kind": "toaster", "order": 3, "httpsURL": "https://z.example.com"])
        json["desktopVaults"] = stored
        let back = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.desktopVaults.map(\.id), ["a", "z"])
        XCTAssertEqual(back.desktopVaults.last?.kind, .mac)
        XCTAssertEqual(back.desktopVaultsSlot, "")
        json.removeValue(forKey: "desktopVaults")
        json.removeValue(forKey: "desktopVaultsSlot")
        let old = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.desktopVaults, [])
        XCTAssertNil(old.desktopVaultsSlot)
    }
}

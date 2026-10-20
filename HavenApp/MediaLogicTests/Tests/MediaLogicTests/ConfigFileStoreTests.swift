import XCTest
@testable import MediaLogic

/// config.json holds the owner's key. A crash mid-write or a file that will
/// not decode must not end in the key being written over with defaults.
final class ConfigFileStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ConfigFileStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func configWithKey() throws -> Data {
        var config = HavenConfig.default
        config.ownerNpub = "npub1owner"
        config.ownerNcryptsec = "ncryptsec1owner"
        config.hasCompletedSetup = true
        return try JSONEncoder().encode(config)
    }

    func testNoFilesIsAFreshInstall() {
        guard case .missing = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else { return XCTFail("expected .missing") }
    }

    /// The case that lost keys: a write cut short leaves half a file. The
    /// last good load comes back from config.json.bak.
    func testTruncatedConfigLoadsFromBackup() throws {
        let good = try configWithKey()
        try store.write(good)
        guard case .loaded(_, fromBackup: false) = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else { return XCTFail("good file should load") }

        try good.prefix(good.count / 2).write(to: store.url)

        guard case .loaded(let config, fromBackup: true) = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else {
            return XCTFail("truncated config.json should fall back to the backup")
        }
        XCTAssertEqual(config.ownerNcryptsec, "ncryptsec1owner")
    }

    /// A truncated file must not replace the backup it would be rescued from.
    func testUnreadableFileDoesNotOverwriteBackup() throws {
        try store.write(try configWithKey())
        _ = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial)
        try Data("{\"owner".utf8).write(to: store.url)
        _ = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial)
        _ = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial)

        let backup = try JSONDecoder().decode(HavenConfig.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.ownerNcryptsec, "ncryptsec1owner")
    }

    /// Tron's path: config.json would not load, .env recovery wrote a valid
    /// config with no key. On the next launch that file decodes, and it must
    /// not replace the backup that still has the key.
    func testKeylessConfigDoesNotReplaceKeyBearingBackup() throws {
        try store.write(try configWithKey())
        _ = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial)

        var keyless = HavenConfig.default
        keyless.hasCompletedSetup = true
        try store.write(try JSONEncoder().encode(keyless))
        guard case .loaded(_, fromBackup: false) = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else {
            return XCTFail("a valid keyless config.json still loads")
        }

        let backup = try JSONDecoder().decode(HavenConfig.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.ownerNcryptsec, "ncryptsec1owner")
    }

    /// With no key on either side the backup still follows config.json.
    func testKeylessConfigRefreshesKeylessBackup() throws {
        var first = HavenConfig.default
        first.relayURL = "first"
        try store.write(try JSONEncoder().encode(first))
        _ = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial)
        var second = HavenConfig.default
        second.relayURL = "second"
        try store.write(try JSONEncoder().encode(second))
        _ = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial)

        let backup = try JSONDecoder().decode(HavenConfig.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.relayURL, "second")
    }

    func testHasKeyMaterial() {
        var config = HavenConfig.default
        XCTAssertFalse(config.hasKeyMaterial)
        config.accountCredentials = ["npub1a": "ncryptsec1a"]
        XCTAssertTrue(config.hasKeyMaterial)
    }

    func testUnreadableWithNoBackup() throws {
        try Data("not json".utf8).write(to: store.url)
        guard case .unreadable = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else { return XCTFail("expected .unreadable") }
    }

    /// Before anything is written over an unreadable file, its bytes are kept.
    func testPreserveUnreadableKeepsTheBytes() throws {
        let broken = Data("{\"ownerNcryptsec\":\"ncryptsec1".utf8)
        try broken.write(to: store.url)

        let copy = try XCTUnwrap(try store.preserveUnreadable(now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(copy.lastPathComponent, "config.json.unreadable-1000")
        XCTAssertEqual(try Data(contentsOf: copy), broken)

        try store.write(try configWithKey())
        XCTAssertEqual(try Data(contentsOf: copy), broken)
    }

    func testPreserveWithNoFileIsANoOp() throws {
        XCTAssertNil(try store.preserveUnreadable())
    }

    func testWriteReplacesTheFile() throws {
        try store.write(Data("old".utf8))
        try store.write(try configWithKey())
        let config = try JSONDecoder().decode(HavenConfig.self, from: Data(contentsOf: store.url))
        XCTAssertEqual(config.ownerNpub, "npub1owner")
    }

    /// Factory reset: the backup goes with the file, or the key would come
    /// back from it on the next launch.
    func testRemoveAllTakesTheBackupToo() throws {
        try store.write(try configWithKey())
        _ = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path))

        store.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        guard case .missing = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else { return XCTFail("expected .missing after reset") }
    }
}

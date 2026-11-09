import XCTest
@testable import MediaLogic

/// config.json, its copies and the DM cache hold private data: each write
/// leaves the file out of backups, also after an atomic replace.
final class PrivateFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func excluded(_ url: URL) throws -> Bool {
        var url = url
        url.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        return try XCTUnwrap(url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }

    func testWriteIsExcludedFromBackupAndProtected() throws {
        let url = dir.appendingPathComponent("dm_cache_owner.json")
        try PrivateFile.write(Data("[]".utf8), to: url)
        XCTAssertTrue(try excluded(url))
        // An atomic write replaces the file; the flag must be set again.
        try PrivateFile.write(Data("[1]".utf8), to: url)
        XCTAssertTrue(try excluded(url))
        XCTAssertEqual(try Data(contentsOf: url), Data("[1]".utf8))
        XCTAssertTrue(PrivateFile.writingOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        XCTAssertTrue(PrivateFile.writingOptions.contains(.atomic))
    }

    func testConfigAndEveryCopyAreExcluded() throws {
        let store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        var config = HavenConfig.default
        config.ownerNpub = "npub1owner"
        config.ownerNcryptsec = "ncryptsec1owner"
        config.hasCompletedSetup = true
        try store.write(JSONEncoder().encode(config))
        XCTAssertTrue(try excluded(store.url))
        guard case .loaded = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else { return XCTFail("should load") }
        XCTAssertTrue(try excluded(store.backupURL))

        try Data("{bad".utf8).write(to: store.url)
        let copy = try XCTUnwrap(store.preserveUnreadable())
        XCTAssertTrue(try excluded(copy))

        try FileManager.default.removeItem(at: store.backupURL)
        try Data("x ncryptsec1owner".utf8).write(to: store.backupURL)
        XCTAssertFalse(try excluded(store.backupURL), "positive control: a plain write is not excluded")
        XCTAssertEqual(store.scrub(["ncryptsec1owner"]), [store.backupURL])
        XCTAssertTrue(try excluded(store.backupURL))
    }
}

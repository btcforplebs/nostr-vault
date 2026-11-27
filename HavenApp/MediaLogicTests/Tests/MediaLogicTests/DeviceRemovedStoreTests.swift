import XCTest
@testable import MediaLogic

/// The "removed here" file on disk (Tron, PR 2652 M1 and S2).
final class DeviceRemovedStoreTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)
    private let owner = String(repeating: "0a", count: 32)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("blossom"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// S2: a list that is not a list is kept aside, not written over by the next add.
    func testCorruptListIsSetAsideNotOverwritten() throws {
        let store = DeviceRemovedStore()
        let file = DeviceRemovedHashes.fileURL(relayDataDir: dir)
        try Data(#"{"byAcc"#.utf8).write(to: file)
        XCTAssertTrue(store.add(sha, owner: owner, relayDataDir: dir))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("removed_here.json.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside)), Data(#"{"byAcc"#.utf8))
        XCTAssertTrue(store.list(relayDataDir: dir).contains(sha))
    }

    /// M1: while the check runs the file is out of the vault folder, under no
    /// name the engine serves; a quit mid-check is put back and unlisted.
    func testSetAsideLeavesTheVaultAndIsRecovered() throws {
        let store = DeviceRemovedStore()
        let vault = dir.appendingPathComponent("blossom")
        let file = vault.appendingPathComponent(sha + ".jpg")
        try Data("bytes".utf8).write(to: file)
        XCTAssertTrue(store.add(sha, owner: owner, relayDataDir: dir))
        let aside = try XCTUnwrap(store.setAside(file, sha256: sha, relayDataDir: dir))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))

        // A pass running during the check leaves it aside.
        store.recoverSetAside(relayDataDir: dir, vault: vault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))

        // The app quit mid-check: a fresh process puts it back.
        let next = DeviceRemovedStore()
        next.recoverSetAside(relayDataDir: dir, vault: vault)
        XCTAssertEqual(try Data(contentsOf: file), Data("bytes".utf8))
        XCTAssertFalse(next.list(relayDataDir: dir).contains(sha))
    }
}

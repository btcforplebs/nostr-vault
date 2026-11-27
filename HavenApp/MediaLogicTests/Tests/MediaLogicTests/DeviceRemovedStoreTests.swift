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

    /// M1: while the check runs every name of the file is out of the vault
    /// folder (Tron, #2654 low 2); a quit mid-check is put back and unlisted.
    func testSetAsideLeavesTheVaultAndIsRecovered() throws {
        let store = DeviceRemovedStore()
        let vault = dir.appendingPathComponent("blossom")
        let other = String(repeating: "cd", count: 32)
        for name in [sha, sha + ".jpg", other] { try Data(name.utf8).write(to: vault.appendingPathComponent(name)) }
        let files = DeviceRemovedStore.vaultFiles(of: sha.uppercased(), in: vault)
        XCTAssertEqual(files.map(\.lastPathComponent), [sha, sha + ".jpg"])
        XCTAssertTrue(store.add(sha, owner: owner, relayDataDir: dir))
        XCTAssertTrue(store.setAside(files, sha256: sha, wasListed: false, relayDataDir: dir))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path), [other])

        // A pass running during the check leaves it aside.
        store.recoverSetAside(relayDataDir: dir, vault: vault)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path), [other])

        // The app quit mid-check: a fresh process puts both back.
        let next = DeviceRemovedStore()
        next.recoverSetAside(relayDataDir: dir, vault: vault)
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent(sha + ".jpg")), Data((sha + ".jpg").utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.appendingPathComponent(sha).path))
        XCTAssertFalse(next.list(relayDataDir: dir).contains(sha))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(DeviceRemovedStore.asideFolder).path), [])
    }

    /// Low 3: a hash listed before the check stays listed when it is put back,
    /// in this process and after a quit.
    func testPutBackKeepsAnEarlierListing() throws {
        let vault = dir.appendingPathComponent("blossom")
        let file = vault.appendingPathComponent(sha)
        for quit in [false, true] {
            let store = DeviceRemovedStore()
            try Data("bytes".utf8).write(to: file)
            XCTAssertTrue(store.add(sha, owner: owner, relayDataDir: dir))
            XCTAssertTrue(store.setAside([file], sha256: sha, wasListed: true, relayDataDir: dir))
            if quit {
                DeviceRemovedStore().recoverSetAside(relayDataDir: dir, vault: vault)
            } else {
                XCTAssertTrue(store.putBack(sha, relayDataDir: dir, vault: vault))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "quit: \(quit)")
            XCTAssertTrue(DeviceRemovedStore().list(relayDataDir: dir).contains(sha), "quit: \(quit)")
        }
        // Not listed before: put back unlists.
        let store = DeviceRemovedStore()
        store.remove(sha, relayDataDir: dir)
        XCTAssertTrue(store.add(sha, owner: owner, relayDataDir: dir))
        XCTAssertTrue(store.setAside([file], sha256: sha, wasListed: false, relayDataDir: dir))
        XCTAssertTrue(store.putBack(sha, relayDataDir: dir, vault: vault))
        XCTAssertFalse(store.list(relayDataDir: dir).contains(sha))
    }

    private struct Refused: Error {}

    /// #2657 low 1: a set-aside that fails half way, and whose undo fails too,
    /// keeps the file aside for recovery instead of removing the folder.
    func testFailedUndoKeepsTheFileAside() throws {
        let vault = dir.appendingPathComponent("blossom")
        let first = vault.appendingPathComponent(sha), second = vault.appendingPathComponent(sha + ".jpg")
        try Data("only copy".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        var calls = 0
        // Move 1 (first aside) works; move 2 (second aside) and move 3 (undo first) fail.
        let store = DeviceRemovedStore(move: { from, to in
            calls += 1
            guard calls == 1 else { throw Refused() }
            try FileManager.default.moveItem(at: from, to: to)
        })
        XCTAssertFalse(store.setAside([first, second], sha256: sha, wasListed: false, relayDataDir: dir))
        let aside = dir.appendingPathComponent(DeviceRemovedStore.asideFolder).appendingPathComponent(sha).appendingPathComponent(sha)
        XCTAssertEqual(try Data(contentsOf: aside), Data("only copy".utf8))
        DeviceRemovedStore().recoverSetAside(relayDataDir: dir, vault: vault)
        XCTAssertEqual(try Data(contentsOf: first), Data("only copy".utf8))
    }

    /// #2657 low 2: a set-aside folder that cannot be read is not put back,
    /// so nothing in it is removed.
    func testUnreadableAsideIsNotRemoved() throws {
        let vault = dir.appendingPathComponent("blossom")
        let file = vault.appendingPathComponent(sha)
        try Data("only copy".utf8).write(to: file)
        let hashDir = dir.appendingPathComponent(DeviceRemovedStore.asideFolder).appendingPathComponent(sha)
        let store = DeviceRemovedStore(listDir: { $0.standardizedFileURL.path == hashDir.standardizedFileURL.path ? nil : try? FileManager.default.contentsOfDirectory(atPath: $0.path) })
        XCTAssertTrue(store.add(sha, owner: owner, relayDataDir: dir))
        XCTAssertTrue(store.setAside([file], sha256: sha, wasListed: false, relayDataDir: dir))
        XCTAssertFalse(store.putBack(sha, relayDataDir: dir, vault: vault))
        XCTAssertEqual(try Data(contentsOf: hashDir.appendingPathComponent(sha)), Data("only copy".utf8))
        XCTAssertTrue(store.list(relayDataDir: dir).contains(sha), "still listed while it is aside")
    }
}

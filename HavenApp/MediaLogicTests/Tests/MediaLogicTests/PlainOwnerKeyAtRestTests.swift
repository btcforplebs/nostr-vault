import Foundation
import Security
import XCTest
@testable import MediaLogic

/// A plaintext owner key never lands in config.json new, and an older
/// build's comes out only once the keychain holds it (PlainOwnerKeyAtRest).
/// Twin of Android's ConfigStoreSaveTest (#2448).
final class PlainOwnerKeyAtRestTests: XCTestCase {

    /// A throwaway key, new every run.
    private func freshNsec() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), errSecSuccess)
        return Bech32.encode(hrp: "nsec", data: Data(bytes))!
    }

    /// The text config.json would get for `config` after `decision`.
    private func fileText(_ config: HavenConfig, _ decision: PlainOwnerKeyAtRest.Decision) throws -> String {
        let data = try JSONEncoder().encode(config.withPlainOwnerKeyOnDisk(decision.onDisk))
        return String(decoding: data, as: UTF8.self)
    }

    /// Every stored key is this owner's (the cases that aren't about ownership).
    private static func mine(_: String) -> PlainOwnerKeyAtRest.Ownership { .matches }

    /// A keychain stand-in that can refuse writes.
    private final class FakeKeychain {
        var value: String?
        var refuses = false
        var stores = 0
        var deletes = 0
        func store(_ v: String) -> Bool { stores += 1; guard !refuses else { return false }; value = v; return true }
        func delete() -> Bool { deletes += 1; value = nil; return true }
    }

    // MARK: - A new key

    func testRefusedWriteLeavesNoKeyInTheFileAndWarns() throws {
        let key = freshNsec()
        var config = HavenConfig.default
        config.ownerNsec = key
        let keychain = FakeKeychain(); keychain.refuses = true
        var state = PlainOwnerKeyAtRest()

        let decision = state.prepareSave(config.ownerNsec, store: keychain.store)

        XCTAssertEqual(decision, .init(onDisk: "", notSaved: true))
        XCTAssertFalse(try fileText(config, decision).contains(key), "a refused key is never written to config.json")
        XCTAssertEqual(config.ownerNsec, key, "it stays in memory for this session")
    }

    func testStoredKeyLeavesNoKeyInTheFile() throws {
        let key = freshNsec()
        var config = HavenConfig.default
        config.ownerNsec = key
        let keychain = FakeKeychain()
        var state = PlainOwnerKeyAtRest()

        let decision = state.prepareSave(config.ownerNsec, store: keychain.store)

        XCTAssertEqual(decision, .init(onDisk: "", notSaved: false))
        XCTAssertEqual(keychain.value, key)
        XCTAssertFalse(try fileText(config, decision).contains(key))
    }

    func testWarningClearsOnceTheKeychainTakesIt() {
        let key = freshNsec()
        let keychain = FakeKeychain(); keychain.refuses = true
        var state = PlainOwnerKeyAtRest()
        XCTAssertTrue(state.prepareSave(key, store: keychain.store).notSaved)

        keychain.refuses = false
        XCTAssertEqual(state.prepareSave(key, store: keychain.store), .init(onDisk: "", notSaved: false))
    }

    func testNoKeyWritesNothingAndStoresNothing() {
        let keychain = FakeKeychain()
        var state = PlainOwnerKeyAtRest()
        XCTAssertEqual(state.prepareSave("  ", store: keychain.store), .init(onDisk: "", notSaved: false))
        XCTAssertEqual(keychain.stores, 0)
    }

    // MARK: - An older build's key in config.json

    func testFileKeyStaysWhileTheKeychainRefusesIt() throws {
        let key = freshNsec()
        var config = HavenConfig.default
        config.ownerNsec = key
        let keychain = FakeKeychain(); keychain.refuses = true
        var (state, inMemory, _) = PlainOwnerKeyAtRest.loaded(fromFile: key, stored: nil, owner: Self.mine)
        XCTAssertEqual(inMemory, key)

        let decision = state.prepareSave(config.ownerNsec, store: keychain.store)

        XCTAssertEqual(decision, .init(onDisk: key, notSaved: false), "kept in the file: it is the only copy")
        XCTAssertTrue(try fileText(config, decision).contains(key))
        XCTAssertNil(state.didSave(onDisk: decision.onDisk, current: config.ownerNsec, delete: keychain.delete),
                     "nothing to scrub from the copies")
    }

    func testFileKeyComesOutOnlyAfterTheKeychainHasIt() throws {
        let key = freshNsec()
        var config = HavenConfig.default
        config.ownerNsec = key
        let keychain = FakeKeychain()
        var (state, _, _) = PlainOwnerKeyAtRest.loaded(fromFile: key, stored: nil, owner: Self.mine)

        let decision = state.prepareSave(config.ownerNsec, store: keychain.store)

        XCTAssertEqual(keychain.value, key, "stored before the file loses it")
        XCTAssertEqual(decision, .init(onDisk: "", notSaved: false))
        XCTAssertFalse(try fileText(config, decision).contains(key))
        XCTAssertEqual(state.didSave(onDisk: decision.onDisk, current: config.ownerNsec, delete: keychain.delete), key,
                       "now scrubbed from config.json's copies")
        XCTAssertEqual(keychain.deletes, 0, "the keychain copy stays: it is the only one now")
        XCTAssertEqual(state.inFile, "")
    }

    func testKeyComesBackFromTheKeychainAtTheNextLaunch() {
        let key = freshNsec()
        let (state, inMemory, _) = PlainOwnerKeyAtRest.loaded(fromFile: "", stored: key, owner: Self.mine)
        XCTAssertEqual(inMemory, key, "still signs after it left the file")
        var again = state
        let keychain = FakeKeychain()
        XCTAssertEqual(again.prepareSave(key, store: keychain.store), .init(onDisk: "", notSaved: false))
        XCTAssertEqual(keychain.stores, 0, "already held: no write")
    }

    func testFileKeyWinsOverAnOlderKeychainCopy() {
        let file = freshNsec(), stored = freshNsec()
        var (state, inMemory, _) = PlainOwnerKeyAtRest.loaded(fromFile: file, stored: stored, owner: Self.mine)
        XCTAssertEqual(inMemory, file)
        let keychain = FakeKeychain(); keychain.value = stored
        XCTAssertEqual(state.prepareSave(file, store: keychain.store), .init(onDisk: "", notSaved: false))
        XCTAssertEqual(keychain.value, file)
    }

    // MARK: - The keychain copy

    func testKeychainCopyIsDeletedOnlyAfterTheKeyIsGoneFromConfig() {
        let key = freshNsec()
        let keychain = FakeKeychain(); keychain.value = key
        var (state, _, _) = PlainOwnerKeyAtRest.loaded(fromFile: "", stored: key, owner: Self.mine)

        // Encrypted into ownerNcryptsec, or removed: ownerNsec is empty.
        let decision = state.prepareSave("", store: keychain.store)
        XCTAssertEqual(keychain.deletes, 0, "not before config.json is written")
        state.didSave(onDisk: decision.onDisk, current: "", delete: keychain.delete)
        XCTAssertEqual(keychain.deletes, 1)
        XCTAssertNil(keychain.value)
    }

    func testUnreadKeychainCopyIsNeverDeleted() {
        // Before first unlock the read finds nothing; an empty config then
        // must not delete a key it never saw.
        let keychain = FakeKeychain(); keychain.value = freshNsec()
        var (state, inMemory, _) = PlainOwnerKeyAtRest.loaded(fromFile: "", stored: nil, owner: Self.mine)
        XCTAssertEqual(inMemory, "")
        let decision = state.prepareSave(inMemory, store: keychain.store)
        state.didSave(onDisk: decision.onDisk, current: inMemory, delete: keychain.delete)
        XCTAssertEqual(keychain.deletes, 0)
        XCTAssertNotNil(keychain.value)
    }

    // MARK: - A keychain key left by an earlier install

    func testAnotherAccountsKeychainKeyIsNotUsedAndIsDeleted() {
        // Key A outlived deleting the app; account B was set up after.
        let a = freshNsec()
        let (state, inMemory, deleteStored) = PlainOwnerKeyAtRest.loaded(fromFile: "", stored: a) { _ in .other }
        XCTAssertEqual(inMemory, "", "never signs as another account")
        XCTAssertEqual(state.inKeychain, "")
        XCTAssertTrue(deleteStored, "a proven mismatch is removed")
    }

    func testUnreadableOwnershipLeavesTheKeyAloneButUnused() {
        let key = freshNsec()
        let keychain = FakeKeychain(); keychain.value = key
        var (state, inMemory, deleteStored) = PlainOwnerKeyAtRest.loaded(fromFile: "", stored: key) { _ in .unreadable }
        XCTAssertEqual(inMemory, "")
        XCTAssertFalse(deleteStored, "only a proven mismatch deletes")
        let decision = state.prepareSave(inMemory, store: keychain.store)
        state.didSave(onDisk: decision.onDisk, current: inMemory, delete: keychain.delete)
        XCTAssertEqual(keychain.deletes, 0)
        XCTAssertEqual(keychain.value, key)
    }

    func testMatchingKeychainKeyIsUsed() {
        let key = freshNsec()
        var asked: [String] = []
        let (_, inMemory, deleteStored) = PlainOwnerKeyAtRest.loaded(fromFile: "", stored: key) { asked.append($0); return .matches }
        XCTAssertEqual(asked, [key])
        XCTAssertEqual(inMemory, key)
        XCTAssertFalse(deleteStored)
    }

    func testFileKeyIsUsedWithoutAskingAboutTheKeychainCopy() {
        let file = freshNsec(), stored = freshNsec()
        var asked = 0
        let (_, inMemory, deleteStored) = PlainOwnerKeyAtRest.loaded(fromFile: file, stored: stored) { _ in asked += 1; return .other }
        XCTAssertEqual(inMemory, file)
        XCTAssertFalse(deleteStored, "the next save overwrites it with the file's key")
        XCTAssertEqual(asked, 0)
    }
}

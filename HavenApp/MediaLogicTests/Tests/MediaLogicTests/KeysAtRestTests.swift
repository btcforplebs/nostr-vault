import Foundation
import Security
import XCTest
@testable import MediaLogic

/// Upgrades from builds that left keys where a device backup carries them:
/// a plaintext owner key and NIP-46 client keys in config.json, and the key
/// passwords in the keychain group the widget shares.
final class KeysAtRestTests: XCTestCase {

    // MARK: - Fixtures

    /// A throwaway key, new every run.
    private func freshHexKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func nsec(_ hex: String) -> String {
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        return Bech32.encode(hrp: "nsec", data: Data(bytes))!
    }

    /// Stand-in NIP-49: reversible, and wrong passwords fail.
    private func fakeEncrypt(_ nsec: String, _ password: String) throws -> String { "enc:\(password):\(nsec)" }
    private func fakeDecrypt(_ blob: String, _ password: String) throws -> String {
        let prefix = "enc:\(password):"
        guard blob.hasPrefix(prefix) else { throw NIP49Service.NIP49Error.decodingFailed }
        return String(blob.dropFirst(prefix.count))
    }

    // MARK: - Upgrade from a plaintext owner key

    func testPlaintextKeyWithNoPasswordIsEncryptedWithANewOne() {
        let hex = freshHexKey()
        var config = HavenConfig.default
        config.ownerNsec = nsec(hex)

        let outcome = config.encryptPlaintextOwnerKey(storedPassword: nil, newPassword: { "new-pw" },
                                                      encrypt: fakeEncrypt, decrypt: fakeDecrypt)

        XCTAssertEqual(outcome, .encrypted(newPassword: "new-pw"))
        XCTAssertEqual(config.ownerNsec, "")
        XCTAssertNil(config.ownerHexKey, "the plaintext signing path is gone")
        XCTAssertEqual(HavenConfig.hexKey(fromNsec: try fakeDecrypt(config.ownerNcryptsec, "new-pw")), hex)
        XCTAssertTrue(config.hasKeyMaterial)
    }

    func testPlaintextKeyUsesTheStoredPassword() throws {
        let hex = freshHexKey()
        var config = HavenConfig.default
        config.ownerNsec = hex  // raw hex, the other legacy form

        let outcome = config.encryptPlaintextOwnerKey(storedPassword: "theirs", newPassword: { XCTFail("no new password"); return "x" },
                                                      encrypt: fakeEncrypt, decrypt: fakeDecrypt)

        XCTAssertEqual(outcome, .encrypted(newPassword: nil))
        XCTAssertEqual(config.ownerNsec, "")
        XCTAssertEqual(HavenConfig.hexKey(fromNsec: try fakeDecrypt(config.ownerNcryptsec, "theirs")), hex)
    }

    func testPlaintextBesideTheSameEncryptedKeyIsCleared() throws {
        let hex = freshHexKey()
        var config = HavenConfig.default
        config.ownerNsec = nsec(hex)
        config.ownerNcryptsec = try fakeEncrypt(nsec(hex), "pw")

        XCTAssertEqual(config.encryptPlaintextOwnerKey(storedPassword: "pw", newPassword: { "x" },
                                                       encrypt: fakeEncrypt, decrypt: fakeDecrypt), .cleared)
        XCTAssertEqual(config.ownerNsec, "")
        XCTAssertEqual(config.ownerNcryptsec, try fakeEncrypt(nsec(hex), "pw"), "the encrypted key is untouched")
    }

    /// The plaintext may be the only copy of its key: never cleared on a guess.
    func testPlaintextIsKeptUnlessTheEncryptedKeyProvesTheSame() throws {
        let hex = freshHexKey()
        let other = try fakeEncrypt(nsec(freshHexKey()), "pw")
        for (stored, ncryptsec) in [(nil as String?, other), ("pw", other), ("wrong", try fakeEncrypt(nsec(hex), "pw"))] {
            var config = HavenConfig.default
            config.ownerNsec = nsec(hex)
            config.ownerNcryptsec = ncryptsec
            XCTAssertEqual(config.encryptPlaintextOwnerKey(storedPassword: stored, newPassword: { "x" },
                                                           encrypt: fakeEncrypt, decrypt: fakeDecrypt), .keptUnverified)
            XCTAssertEqual(config.ownerNsec, nsec(hex))
            XCTAssertEqual(config.ownerNcryptsec, ncryptsec)
        }
    }

    func testAFailedEncryptionChangesNothing() {
        let hex = freshHexKey()
        var config = HavenConfig.default
        config.ownerNsec = nsec(hex)
        let outcome = config.encryptPlaintextOwnerKey(storedPassword: nil, newPassword: { "pw" },
                                                      encrypt: { _, _ in "garbage" }, decrypt: fakeDecrypt)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(config.ownerNsec, nsec(hex))
        XCTAssertEqual(config.ownerNcryptsec, "")
    }

    func testNoPlaintextKeyIsNothingToDo() {
        var config = HavenConfig.default
        config.ownerNcryptsec = "ncryptsec1abc"
        XCTAssertEqual(config.encryptPlaintextOwnerKey(storedPassword: nil, newPassword: { "x" },
                                                       encrypt: fakeEncrypt, decrypt: fakeDecrypt), .nothingToDo)
        XCTAssertEqual(config.ownerNcryptsec, "ncryptsec1abc")
    }

    // MARK: - The copies beside config.json

    func testScrubTakesTheKeyOutOfTheBackupAndUnreadableCopiesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KeysAtRest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        let key = nsec(freshHexKey())
        let otherKey = nsec(freshHexKey())

        var config = HavenConfig.default
        config.ownerNsec = key
        try JSONEncoder().encode(config).write(to: store.backupURL)
        let unreadable = dir.appendingPathComponent("config.json.unreadable-1700000000")
        try Data("{\"ownerNsec\":\"\(key)\", \"cut off".utf8).write(to: unreadable)
        let unrelated = dir.appendingPathComponent("notes.txt")
        try Data(key.utf8).write(to: unrelated)
        let otherCopy = dir.appendingPathComponent("config.json.unreadable-1700000001")
        try Data("{\"ownerNsec\":\"\(otherKey)\"}".utf8).write(to: otherCopy)

        let rewritten = store.scrub([key, ""])

        XCTAssertEqual(Set(rewritten.map(\.lastPathComponent)), ["config.json.bak", "config.json.unreadable-1700000000"])
        for file in [store.backupURL, unreadable] {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(key), file.lastPathComponent)
        }
        let backup = try JSONDecoder().decode(HavenConfig.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.ownerNsec, "", "the backup still decodes")
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), key, "only config.json's copies")
        XCTAssertTrue(try String(contentsOf: otherCopy, encoding: .utf8).contains(otherKey), "another key is left alone")
    }

    // MARK: - NIP-46 client keys out of config.json

    func testClientKeysLeaveTheFileOnlyOnceTheKeychainHoldsThem() throws {
        var config = HavenConfig.default
        config.nip46ClientSecretKey = "global-sk"
        config.accountBunkerConfigs["npub1a"] = AccountBunkerConfig(bunkerURI: "bunker://x", clientSecretKey: "a-sk")
        config.accountBunkerConfigs["npub1b"] = AccountBunkerConfig(bunkerURI: "bunker://y", clientSecretKey: "b-sk")

        var keychain: [String: String] = [:]
        var sync = NIP46SecretSync()
        let held = sync.sync(config.nip46ClientSecrets,
                             store: { value, account in
                                 guard account != HavenConfig.nip46ClientSecretAccount(forNpub: "npub1b") else { return false }
                                 keychain[account] = value; return true },
                             delete: { keychain[$0] = nil; return true })

        let disk = String(decoding: try JSONEncoder().encode(config.withoutNIP46ClientSecrets(inKeychain: held)), as: UTF8.self)
        XCTAssertFalse(disk.contains("global-sk"))
        XCTAssertFalse(disk.contains("a-sk"))
        XCTAssertTrue(disk.contains("b-sk"), "the keychain refused it, so the file keeps it")
        XCTAssertEqual(keychain, ["nip46-client-secret": "global-sk", "nip46-client-secret-npub1a": "a-sk"])

        // Next launch: the file has no keys; the keychain fills them back in.
        var loaded = try JSONDecoder().decode(HavenConfig.self, from: Data(disk.utf8))
        loaded.attachNIP46ClientSecrets { keychain[$0] }
        XCTAssertEqual(loaded.nip46ClientSecretKey, "global-sk")
        XCTAssertEqual(loaded.accountBunkerConfigs["npub1a"]?.clientSecretKey, "a-sk")
        XCTAssertEqual(loaded.accountBunkerConfigs["npub1b"]?.clientSecretKey, "b-sk")
    }

    func testARemovedSignerLeavesTheKeychain() {
        var keychain = ["nip46-client-secret-npub1a": "a-sk"]
        var sync = NIP46SecretSync(synced: keychain)
        _ = sync.sync([:], store: { _, _ in true }, delete: { keychain[$0] = nil; return true })
        XCTAssertTrue(keychain.isEmpty)
    }

    /// Loaded before the first unlock: the keychain read nothing. A save then
    /// must not delete the keys it could not see.
    func testAnUnreadableKeychainIsNeverEmptied() {
        var deleted: [String] = []
        var sync = NIP46SecretSync(synced: [:])
        let held = sync.sync([:], store: { _, _ in false }, delete: { deleted.append($0); return true })
        XCTAssertTrue(held.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testAnUnchangedKeyIsNotRewritten() {
        var writes = 0
        var sync = NIP46SecretSync(synced: ["nip46-client-secret": "sk"])
        let held = sync.sync(["nip46-client-secret": "sk"], store: { _, _ in writes += 1; return true }, delete: { _ in true })
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(held, ["nip46-client-secret"])
    }

    // MARK: - Upgrade from the shared keychain group

    private let shared = "525WQ48Y72.nostrvault.shared"
    private let mine = "525WQ48Y72.com.havenapp.relay"
    private let oldClass = kSecAttrAccessibleAfterFirstUnlock as String

    func testPasswordsMoveFromTheSharedGroupIntoTheAppsOwn() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "owner-pw", group: shared, accessible: oldClass)
        keychain.put("account-key-password-npub1x", "acct-pw", group: shared, accessible: CredentialStore.accessible)

        XCTAssertEqual(CredentialStore.migrateToThisDeviceOnly(in: keychain, privateGroup: mine), 2)

        XCTAssertEqual(Set(keychain.rows.map(\.group)), [mine], "nothing left where the widget can read it")
        XCTAssertEqual(Set(keychain.rows.map(\.accessible)), [CredentialStore.accessible])
        XCTAssertEqual(CredentialStore.get(account: "owner-key-password", in: keychain, privateGroup: mine), "owner-pw")
        XCTAssertEqual(CredentialStore.get(account: "account-key-password-npub1x", in: keychain, privateGroup: mine), "acct-pw")
        XCTAssertNil(keychain.data(service: CredentialStore.service, account: "owner-key-password", group: shared),
                     "a widget query of its own group finds nothing")

        XCTAssertEqual(CredentialStore.migrateToThisDeviceOnly(in: keychain, privateGroup: mine), 0, "second launch: nothing to do")
    }

    /// Before the first unlock the add fails: the old item stays, still
    /// readable, and moves next time.
    func testAFailedMoveKeepsTheOldPassword() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "owner-pw", group: shared, accessible: oldClass)
        keychain.addStatus = errSecInteractionNotAllowed

        XCTAssertEqual(CredentialStore.migrateToThisDeviceOnly(in: keychain, privateGroup: mine), 0)
        XCTAssertEqual(CredentialStore.get(account: "owner-key-password", in: keychain, privateGroup: mine), "owner-pw")

        keychain.addStatus = nil
        XCTAssertEqual(CredentialStore.migrateToThisDeviceOnly(in: keychain, privateGroup: mine), 1)
        XCTAssertEqual(keychain.rows.map(\.group), [mine])
    }

    /// A newer password already in the app's group wins over the shared copy.
    func testAStaleSharedCopyIsDroppedNotCopiedOver() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "old-pw", group: shared, accessible: oldClass)
        keychain.put("owner-key-password", "new-pw", group: mine, accessible: CredentialStore.accessible)

        CredentialStore.migrateToThisDeviceOnly(in: keychain, privateGroup: mine)

        XCTAssertEqual(keychain.rows.count, 1)
        XCTAssertEqual(CredentialStore.get(account: "owner-key-password", in: keychain, privateGroup: mine), "new-pw")
    }

    func testNewPasswordsGoStraightToTheAppsGroup() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "old-pw", group: shared, accessible: oldClass)
        XCTAssertTrue(CredentialStore.store("new-pw", account: "owner-key-password", in: keychain, privateGroup: mine))
        XCTAssertEqual(keychain.rows, [FakeKeychain.Row(account: "owner-key-password", group: mine,
                                                        accessible: CredentialStore.accessible, data: Data("new-pw".utf8))])
    }
}

/// An in-memory keychain with the semantics CredentialStore relies on: a nil
/// group matches any group for reads and deletes, and an add into a group
/// that already holds the account is a duplicate.
final class FakeKeychain: CredentialKeychain {
    struct Row: Equatable { var account: String; var group: String; var accessible: String; var data: Data }
    var rows: [Row] = []
    var addStatus: OSStatus?
    let defaultGroup = "525WQ48Y72.nostrvault.shared"

    func put(_ account: String, _ value: String, group: String, accessible: String) {
        rows.append(Row(account: account, group: group, accessible: accessible, data: Data(value.utf8)))
    }

    private func matches(_ row: Row, _ account: String?, _ group: String?) -> Bool {
        (account == nil || row.account == account) && (group == nil || row.group == group)
    }

    func items(service: String) -> [CredentialKeychainItem] {
        rows.map { CredentialKeychainItem(account: $0.account, group: $0.group, accessible: $0.accessible) }
    }

    func data(service: String, account: String, group: String?) -> Data? {
        rows.first { matches($0, account, group) }?.data
    }

    func add(service: String, account: String, data: Data, group: String?, accessible: String) -> OSStatus {
        if let addStatus { return addStatus }
        let group = group ?? defaultGroup
        if rows.contains(where: { matches($0, account, group) }) { return errSecDuplicateItem }
        rows.append(Row(account: account, group: group, accessible: accessible, data: data))
        return errSecSuccess
    }

    func updateAccessible(service: String, account: String, group: String?, to accessible: String) -> OSStatus {
        var hit = false
        for i in rows.indices where matches(rows[i], account, group) { rows[i].accessible = accessible; hit = true }
        return hit ? errSecSuccess : errSecItemNotFound
    }

    func delete(service: String, account: String?, group: String?) -> OSStatus {
        let before = rows.count
        rows.removeAll { matches($0, account, group) }
        return rows.count < before ? errSecSuccess : errSecItemNotFound
    }
}

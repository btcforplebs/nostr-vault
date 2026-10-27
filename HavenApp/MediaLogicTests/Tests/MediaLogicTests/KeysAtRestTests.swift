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

    /// Stand-in key-to-pubkey: deterministic, and distinct per key.
    private func pub(_ secret: String) -> String? { secret.isEmpty ? nil : "pub-\(secret)" }

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
        loaded.attachNIP46ClientSecrets({ keychain[$0] }, pubkeyOf: pub)
        XCTAssertEqual(loaded.nip46ClientSecretKey, "global-sk")
        XCTAssertEqual(loaded.accountBunkerConfigs["npub1a"]?.clientSecretKey, "a-sk")
        XCTAssertEqual(loaded.accountBunkerConfigs["npub1b"]?.clientSecretKey, "b-sk")
    }

    /// 2.7.2 over 3.0.0 (LogePhone, 2026-10-27): the older build found the
    /// file's keys blank, made a fresh unpaired one and saved it in the file
    /// (with its own nip46ClientPubkey). Back on this build the paired
    /// keychain key must win, or the signer keeps answering "Invalid or
    /// missing bunker secret".
    func testThePairedKeychainKeyBeatsAnUnpairedFileKey() {
        var config = HavenConfig.default
        config.ownerNpub = "npub1a"
        config.nip46ClientSecretKey = "fresh-unpaired-sk"
        config.nip46ClientPubkey = "pub-fresh-unpaired-sk"
        config.accountBunkerConfigs["npub1a"] = AccountBunkerConfig(bunkerURI: "bunker://x", clientSecretKey: "",
                                                                    clientPubkey: "pub-paired-a-sk")
        config.accountBunkerConfigs["npub1b"] = AccountBunkerConfig(bunkerURI: "bunker://y", clientSecretKey: "file-only-sk",
                                                                    clientPubkey: "pub-file-only-sk")
        config.accountBunkerConfigs["npub1c"] = AccountBunkerConfig(bunkerURI: "bunker://z", clientSecretKey: "stray-c-sk",
                                                                    clientPubkey: "pub-paired-c-sk")
        let keychain = ["nip46-client-secret": "paired-a-sk", "nip46-client-secret-npub1a": "paired-a-sk",
                        "nip46-client-secret-npub1c": "paired-c-sk"]

        let dropped = config.attachNIP46ClientSecrets({ keychain[$0] }, pubkeyOf: pub)

        XCTAssertEqual(config.nip46ClientSecretKey, "paired-a-sk",
                       "the shared slot is judged by the active account's entry, not the rewritten nip46ClientPubkey")
        XCTAssertEqual(config.accountBunkerConfigs["npub1a"]?.clientSecretKey, "paired-a-sk")
        XCTAssertEqual(config.accountBunkerConfigs["npub1b"]?.clientSecretKey, "file-only-sk",
                       "a key only the file holds is kept")
        XCTAssertEqual(config.accountBunkerConfigs["npub1c"]?.clientSecretKey, "paired-c-sk")
        XCTAssertEqual(Set(dropped), ["fresh-unpaired-sk", "stray-c-sk"])
    }

    /// The mirror case: paired again on a build without the keychain (master,
    /// 2.7.x), which saved the new key and its pubkey in the file. The old
    /// keychain key must not win, or the next save writes the file blank and
    /// the new pairing is lost.
    func testANewPairingInTheFileBeatsAStaleKeychainKey() {
        var config = HavenConfig.default
        config.ownerNpub = "npub1a"
        config.nip46BunkerURI = "bunker://new"
        config.nip46ClientSecretKey = "new-sk"
        config.nip46ClientPubkey = "pub-new-sk"
        config.accountBunkerConfigs["npub1a"] = AccountBunkerConfig(bunkerURI: "bunker://new", clientSecretKey: "new-sk",
                                                                    clientPubkey: "pub-new-sk")
        var keychain = ["nip46-client-secret": "old-sk", "nip46-client-secret-npub1a": "old-sk"]
        var sync = NIP46SecretSync(synced: keychain)

        let dropped = config.attachNIP46ClientSecrets({ keychain[$0] }, pubkeyOf: pub)

        XCTAssertEqual(config.nip46ClientSecretKey, "new-sk")
        XCTAssertEqual(config.accountBunkerConfigs["npub1a"]?.clientSecretKey, "new-sk")
        XCTAssertTrue(dropped.isEmpty)

        // The save that follows moves the new key into the keychain.
        let held = sync.sync(config.nip46ClientSecrets,
                             store: { keychain[$1] = $0; return true },
                             delete: { keychain[$0] = nil; return true })
        XCTAssertEqual(keychain, ["nip46-client-secret": "new-sk", "nip46-client-secret-npub1a": "new-sk"])
        XCTAssertEqual(held.count, 2)
    }

    /// No saved pubkey, or neither key matches it: the keychain wins.
    func testTheKeychainWinsWhenThePubkeysCannotTell() {
        for paired in ["", "pub-someone-else"] {
            var config = HavenConfig.default
            config.accountBunkerConfigs["npub1a"] = AccountBunkerConfig(bunkerURI: "bunker://x", clientSecretKey: "file-sk",
                                                                        clientPubkey: paired)
            let keychain = ["nip46-client-secret-npub1a": "keychain-sk"]
            config.attachNIP46ClientSecrets({ keychain[$0] }, pubkeyOf: pub)
            XCTAssertEqual(config.accountBunkerConfigs["npub1a"]?.clientSecretKey, "keychain-sk", paired)
        }
    }

    /// The keychain refused a new key while holding the old one: the old one
    /// goes, so it cannot win over the file's new key at the next load.
    func testARefusedWriteDropsTheStaleKeychainCopy() {
        var keychain = ["nip46-client-secret": "old-sk"]
        var sync = NIP46SecretSync(synced: keychain)
        let held = sync.sync(["nip46-client-secret": "new-sk"],
                             store: { _, _ in false },
                             delete: { keychain[$0] = nil; return true })
        XCTAssertTrue(held.isEmpty, "the file keeps the new key")
        XCTAssertTrue(keychain.isEmpty)

        var config = HavenConfig.default
        config.nip46ClientSecretKey = "new-sk"
        config.attachNIP46ClientSecrets({ keychain[$0] }, pubkeyOf: pub)
        XCTAssertEqual(config.nip46ClientSecretKey, "new-sk")
    }

    /// A blank live key is never replaced by a fresh one while the account's
    /// paired key can be found.
    func testAPairedKeyIsFoundBeforeANewOneIsMade() {
        var config = HavenConfig.default
        config.ownerNpub = "npub1owner"
        config.accountBunkerConfigs["npub1a"] = AccountBunkerConfig(bunkerURI: "bunker://x", clientSecretKey: "a-sk")
        config.accountBunkerConfigs["npub1b"] = AccountBunkerConfig(bunkerURI: "bunker://y", clientSecretKey: "")
        config.accountBunkerConfigs["npub1c"] = AccountBunkerConfig(bunkerURI: "bunker://z", clientSecretKey: "")
        let keychain = ["nip46-client-secret": "shared-slot-sk", "nip46-client-secret-npub1b": "b-sk"]

        XCTAssertEqual(config.pairedNIP46ClientSecret(forNpub: "npub1a") { keychain[$0] }, "a-sk")
        XCTAssertEqual(config.pairedNIP46ClientSecret(forNpub: "npub1b") { keychain[$0] }, "b-sk")
        XCTAssertNil(config.pairedNIP46ClientSecret(forNpub: "npub1c") { keychain[$0] },
                     "the shared slot may be another account's key")
        XCTAssertEqual(config.pairedNIP46ClientSecret(forNpub: "npub1owner") { keychain[$0] }, "shared-slot-sk",
                       "an owner set up without an entry of its own uses the shared slot")
        XCTAssertNil(HavenConfig.default.pairedNIP46ClientSecret(forNpub: "npub1owner") { _ in nil })
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

    /// If a search ever leaves the group out, a delete without one would hit
    /// every group, the new copy included. Such an item is left as it is.
    func testAnItemListedWithoutItsGroupIsNeverDeleted() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "owner-pw", group: shared, accessible: oldClass)
        keychain.listsGroups = false

        XCTAssertEqual(CredentialStore.migrateToThisDeviceOnly(in: keychain, privateGroup: mine), 0)
        XCTAssertEqual(CredentialStore.get(account: "owner-key-password", in: keychain, privateGroup: mine), "owner-pw")
    }

    /// A write that fails must leave the old password: it may be the only
    /// way to decrypt the key.
    func testAFailedWriteKeepsTheOldPassword() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "old-pw", group: mine, accessible: CredentialStore.accessible)
        keychain.addStatus = errSecInteractionNotAllowed

        XCTAssertFalse(CredentialStore.store("new-pw", account: "owner-key-password", in: keychain, privateGroup: mine))
        XCTAssertEqual(CredentialStore.get(account: "owner-key-password", in: keychain, privateGroup: mine), "old-pw")
    }

    func testStoreReplacesTheValueInTheAppsGroup() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "old-pw", group: mine, accessible: CredentialStore.accessible)
        XCTAssertTrue(CredentialStore.store("new-pw", account: "owner-key-password", in: keychain, privateGroup: mine))
        XCTAssertEqual(keychain.rows.count, 1)
        XCTAssertEqual(CredentialStore.get(account: "owner-key-password", in: keychain, privateGroup: mine), "new-pw")
    }

    /// Only "not found" means there is no password; a locked keychain is not that.
    func testALockedReadIsNotAMissingPassword() {
        final class Locked: CredentialKeychain {
            func items(service: String) -> [CredentialKeychainItem] { [] }
            func read(service: String, account: String, group: String?) -> (data: Data?, status: OSStatus) { (nil, errSecInteractionNotAllowed) }
            func add(service: String, account: String, data: Data, group: String?, accessible: String) -> OSStatus { errSecInteractionNotAllowed }
            func updateData(service: String, account: String, group: String?, data: Data, accessible: String) -> OSStatus { errSecInteractionNotAllowed }
            func updateAccessible(service: String, account: String, group: String?, to accessible: String) -> OSStatus { errSecInteractionNotAllowed }
            func delete(service: String, account: String?, group: String?) -> OSStatus { errSecInteractionNotAllowed }
        }
        let locked = CredentialStore.lookUp(account: "owner-key-password", in: Locked(), privateGroup: mine)
        XCTAssertNil(locked.password)
        XCTAssertEqual(locked.status, errSecInteractionNotAllowed)
        XCTAssertEqual(CredentialStore.lookUp(account: "owner-key-password", in: FakeKeychain(), privateGroup: mine).status,
                       errSecItemNotFound)
    }

    func testFactoryResetTakesTheUnreadableCopiesToo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KeysAtRest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        for name in ["config.json", "config.json.bak", "config.json.unreadable-1700000000", "notes.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        store.removeAll()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["notes.txt"])
    }

    func testTheReportSaysWhenAKeyIsStillShared() {
        let keychain = FakeKeychain()
        keychain.put("owner-key-password", "owner-pw", group: shared, accessible: oldClass)
        XCTAssertEqual(CredentialStore.locationReport(in: keychain), "owner password in \(shared)")
        XCTAssertFalse(CredentialStore.locationReport(in: keychain).contains("owner-pw"), "groups only, never values")
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
    struct Row: Equatable { var account: String; var group: String; var accessible: String; var data: Data; var service = CredentialStore.service }
    var rows: [Row] = []
    var addStatus: OSStatus?
    /// A search whose attributes leave out the access group.
    var listsGroups = true
    let defaultGroup = "525WQ48Y72.nostrvault.shared"

    func put(_ account: String, _ value: String, group: String, accessible: String,
             service: String = CredentialStore.service) {
        rows.append(Row(account: account, group: group, accessible: accessible, data: Data(value.utf8), service: service))
    }

    private func matches(_ row: Row, _ service: String, _ account: String?, _ group: String?) -> Bool {
        row.service == service && (account == nil || row.account == account) && (group == nil || row.group == group)
    }

    func items(service: String) -> [CredentialKeychainItem] {
        rows.filter { $0.service == service }.map { CredentialKeychainItem(account: $0.account, group: listsGroups ? $0.group : nil, accessible: $0.accessible) }
    }

    func read(service: String, account: String, group: String?) -> (data: Data?, status: OSStatus) {
        let data = rows.first { matches($0, service, account, group) }?.data
        return (data, data == nil ? errSecItemNotFound : errSecSuccess)
    }

    func updateData(service: String, account: String, group: String?, data: Data, accessible: String) -> OSStatus {
        if let addStatus { return addStatus }
        var hit = false
        for i in rows.indices where matches(rows[i], service, account, group) {
            rows[i].data = data; rows[i].accessible = accessible; hit = true
        }
        return hit ? errSecSuccess : errSecItemNotFound
    }

    func add(service: String, account: String, data: Data, group: String?, accessible: String) -> OSStatus {
        if let addStatus { return addStatus }
        let group = group ?? defaultGroup
        if rows.contains(where: { matches($0, service, account, group) }) { return errSecDuplicateItem }
        rows.append(Row(account: account, group: group, accessible: accessible, data: data, service: service))
        return errSecSuccess
    }

    func updateAccessible(service: String, account: String, group: String?, to accessible: String) -> OSStatus {
        var hit = false
        for i in rows.indices where matches(rows[i], service, account, group) { rows[i].accessible = accessible; hit = true }
        return hit ? errSecSuccess : errSecItemNotFound
    }

    func delete(service: String, account: String?, group: String?) -> OSStatus {
        let before = rows.count
        rows.removeAll { matches($0, service, account, group) }
        return rows.count < before ? errSecSuccess : errSecItemNotFound
    }
}

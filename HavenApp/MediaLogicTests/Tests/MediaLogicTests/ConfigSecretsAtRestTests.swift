import Foundation
import XCTest
@testable import MediaLogic

/// Upgrading an install whose config.json holds the wallet connection, the
/// backup bucket's credentials and the NIP-46 signer links as plaintext
/// (HavenConfig+ConfigSecrets). The fixture is a config.json in that shape.
final class ConfigSecretsAtRestTests: XCTestCase {

    /// Every secret the fixture holds, raw. None may be readable on disk
    /// after the migration, raw or JSON-escaped.
    private let fixtureSecrets = [
        "nostr+walletconnect://fixture-wallet-pubkey?relay=wss://relay.example.invalid&secret=fixture-nwc-secret",
        "bunker://fixture-signer-pubkey?relay=wss://signer.example.invalid&secret=fixture-connect-secret",
        "bunker://fixture-second-signer?relay=wss://signer.example.invalid&secret=fixture-second-secret",
        "fixture-nwc-secret", "fixture-connect-secret", "fixture-second-secret",
        "FIXTUREACCESSKEYID", "fixture-s3-secret-key",
    ]

    private func fixtureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "config-before-keychain", withExtension: "json",
                                                      subdirectory: "Fixtures/ConfigSecrets"))
        try FileManager.default.copyItem(at: fixture, to: dir.appendingPathComponent("config.json"))
        return dir
    }

    private func loadConfig(_ store: ConfigFileStore) throws -> HavenConfig {
        guard case .loaded(let config, let fromBackup) = store.load(HavenConfig.self, hasKey: \.hasKeyMaterial) else {
            XCTFail("config.json did not load"); throw CocoaError(.fileReadCorruptFile)
        }
        XCTAssertFalse(fromBackup)
        return config
    }

    /// A keychain as a dictionary, with accounts it refuses to take.
    private final class FakeKeychain {
        var items: [String: String] = [:]
        var refuses: Set<String> = []
        func store(_ value: String, _ account: String) -> Bool {
            guard !refuses.contains(account) else { return false }
            items[account] = value; return true
        }
        func delete(_ account: String) -> Bool { items[account] = nil; return true }
    }

    /// What ConfigService does at launch and on save, without the app.
    private func launchAndSave(_ store: ConfigFileStore, keychain: FakeKeychain) throws -> HavenConfig {
        var config = try loadConfig(store)
        let plaintext = Array(config.configSecrets.values)
        var stored: [String: String] = [:]
        config.attachConfigSecrets { account in
            let value = keychain.items[account]
            stored[account] = value
            return value
        }
        var sync = NIP46SecretSync(synced: stored)
        let held = sync.sync(config.configSecrets, store: keychain.store, delete: keychain.delete)
        try store.write(JSONEncoder().encode(config.withoutConfigSecrets(inKeychain: held)))
        let heldValues = Set(held.compactMap { sync.synced[$0] })
        store.scrub(HavenConfig.scrubNeedles(for: plaintext.filter { heldValues.contains($0) }),
                    replacingWith: HavenConfig.emptyJSONString)
        return config
    }

    private func assertNoSecrets(in file: URL, file callerFile: StaticString = #filePath, line: UInt = #line) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        for secret in fixtureSecrets + fixtureSecrets.map({ $0.replacingOccurrences(of: "/", with: "\\/") }) {
            XCTAssertFalse(text.contains(secret), "\(file.lastPathComponent) still holds \(secret)", file: callerFile, line: line)
        }
    }

    func testAnExistingInstallMigratesAndLosesNothing() throws {
        let dir = try fixtureDir()
        let store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        let before = try loadConfig(store)
        XCTAssertFalse(before.nwcURI.isEmpty, "the fixture holds the secrets")

        let keychain = FakeKeychain()
        let migrated = try launchAndSave(store, keychain: keychain)
        XCTAssertEqual(migrated.nwcURI, before.nwcURI, "the running app keeps every value")
        XCTAssertEqual(migrated.accountBunkerConfigs, before.accountBunkerConfigs)

        // On disk: config.json and the backup it made at load hold none of them.
        try assertNoSecrets(in: store.url)
        try assertNoSecrets(in: store.backupURL)
        let backup = try JSONDecoder().decode(HavenConfig.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.ownerNcryptsec, "ncryptsec1fixtureencryptedkey", "the scrubbed backup still decodes, key intact")
        let disk = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(disk.contains("ncryptsec1fixtureencryptedkey"), "the encrypted owner key stays")
        XCTAssertTrue(disk.contains("fixture-signer-pubkey"), "the signer's pubkey stays: it tells a signing account")
        XCTAssertEqual(keychain.items.count, 9)

        // Next launch: config.json is blank there; the keychain fills it all back in.
        let relaunched = try launchAndSave(store, keychain: keychain)
        XCTAssertEqual(relaunched.nwcURI, before.nwcURI)
        XCTAssertEqual(relaunched.s3AccessKeyId, before.s3AccessKeyId)
        XCTAssertEqual(relaunched.s3SecretKey, before.s3SecretKey)
        XCTAssertEqual(relaunched.nip46BunkerURI, before.nip46BunkerURI)
        XCTAssertEqual(relaunched.nip46Secret, before.nip46Secret)
        XCTAssertEqual(relaunched.accountBunkerConfigs, before.accountBunkerConfigs)
        XCTAssertEqual(relaunched.activeSigningMode(), before.activeSigningMode(), "signing still goes to the signer")
        XCTAssertEqual(keychain.items.count, 9)
        try assertNoSecrets(in: store.url)
        try assertNoSecrets(in: store.backupURL)
    }

    func testARefusedKeychainWriteKeepsTheSecretInTheFile() throws {
        let dir = try fixtureDir()
        let store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        let keychain = FakeKeychain()
        keychain.refuses = [HavenConfig.nwcURIAccount]
        _ = try launchAndSave(store, keychain: keychain)

        let disk = try loadConfig(store)
        XCTAssertFalse(disk.nwcURI.isEmpty, "the keychain refused it, so the file keeps it")
        XCTAssertEqual(disk.s3SecretKey, "", "the rest moved")
        let backup = try String(contentsOf: store.backupURL, encoding: .utf8)
        XCTAssertTrue(backup.contains("fixture-nwc-secret"), "a value the keychain did not take is not scrubbed")
        XCTAssertFalse(backup.contains("fixture-s3-secret-key"), "one it took is")
    }

    func testAValueInTheFileBeatsTheKeychain() {
        var config = HavenConfig.default
        config.nwcURI = "nostr+walletconnect://reconnected-on-an-older-build"
        config.accountBunkerConfigs["npub1a"] = AccountBunkerConfig(bunkerURI: "", signerPubkey: "pk", secret: "")
        config.attachConfigSecrets { account in
            [HavenConfig.nwcURIAccount: "nostr+walletconnect://stale",
             HavenConfig.nip46BunkerURIAccount(forNpub: "npub1a"): "bunker://from-keychain"][account]
        }
        XCTAssertEqual(config.nwcURI, "nostr+walletconnect://reconnected-on-an-older-build")
        XCTAssertEqual(config.accountBunkerConfigs["npub1a"]?.bunkerURI, "bunker://from-keychain")
        XCTAssertEqual(config.accountBunkerConfigs["npub1a"]?.secret, "")
    }

    func testDisconnectingAndRemovingAnAccountEmptyTheKeychain() {
        var config = HavenConfig.default
        config.nwcURI = "nostr+walletconnect://w"
        config.accountBunkerConfigs["npub1a"] = AccountBunkerConfig(bunkerURI: "bunker://a", secret: "a-secret")
        let keychain = FakeKeychain()
        var sync = NIP46SecretSync()
        _ = sync.sync(config.configSecrets, store: keychain.store, delete: keychain.delete)
        XCTAssertEqual(keychain.items.count, 3)

        config.nwcURI = ""
        config.accountBunkerConfigs["npub1a"] = nil
        _ = sync.sync(config.configSecrets, store: keychain.store, delete: keychain.delete)
        XCTAssertEqual(keychain.items, [:])
    }

    func testAnUnreadableKeychainIsNeverEmptied() {
        // After the move the file is blank; a launch that reads nothing from
        // the keychain must not delete what it holds.
        let keychain = FakeKeychain()
        keychain.items = [HavenConfig.nwcURIAccount: "nostr+walletconnect://w"]
        var config = HavenConfig.default
        var stored: [String: String] = [:]
        config.attachConfigSecrets { account in stored[account] = nil; return nil }
        var sync = NIP46SecretSync(synced: stored)
        _ = sync.sync(config.configSecrets, store: keychain.store, delete: keychain.delete)
        XCTAssertEqual(keychain.items[HavenConfig.nwcURIAccount], "nostr+walletconnect://w")
    }

    func testScrubFindsAURIAsJSONEncoderWritesIt() throws {
        let uri = "nostr+walletconnect://abc?relay=wss://r.example&secret=s"
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(["nwcURI": uri]), encoding: .utf8))
        XCTAssertFalse(json.contains(uri), "JSONEncoder escapes the slashes")
        var text = json
        for needle in HavenConfig.scrubNeedles(for: [uri]) {
            text = text.replacingOccurrences(of: needle, with: HavenConfig.emptyJSONString)
        }
        XCTAssertEqual(text, #"{"nwcURI":""}"#)
    }

    func testAShortSecretIsScrubbedOnlyWhereItIsTheWholeValue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
        var config = HavenConfig.default
        config.ownerNcryptsec = "ncryptsec1q1q1q1"
        config.nip46Secret = "1"
        try JSONEncoder().encode(config).write(to: store.backupURL)

        store.scrub(HavenConfig.scrubNeedles(for: ["1"]), replacingWith: HavenConfig.emptyJSONString)

        let back = try JSONDecoder().decode(HavenConfig.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(back.nip46Secret, "")
        XCTAssertEqual(back.ownerNcryptsec, "ncryptsec1q1q1q1", "the key is untouched")
        XCTAssertEqual(back.relayPort, config.relayPort)
    }
}

import XCTest
@testable import MediaLogic

/// The signing key is opened once a session, never on the main thread for a
/// signature (Tod 2026-11-10): every like, post, follow, DM and relay AUTH
/// used to run the NIP-49 scrypt again, on the main actor.
final class SigningKeyCacheTests: XCTestCase {

    /// A derivation that counts its runs and answers "hex-of-<ncryptsec>".
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var runs: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    private func makeCache(_ counter: Counter, delay: TimeInterval = 0) -> SigningKeyCache {
        SigningKeyCache { ncryptsec, password in
            counter.bump()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard password == "right" else { throw NSError(domain: "wrong", code: 1) }
            return "hex-of-\(ncryptsec)"
        }
    }

    func testOneDerivationForManySignatures() throws {
        let counter = Counter()
        let cache = makeCache(counter)
        let source = SigningKeySource.locked(ncryptsec: "ncryptsec1aaa", password: "right")
        for _ in 0..<50 { XCTAssertEqual(try cache.hexKey(for: source), "hex-of-ncryptsec1aaa") }
        XCTAssertEqual(counter.runs, 1)
        XCTAssertEqual(cache.derivations, 1)
    }

    func testConcurrentAskersShareOneDerivation() async throws {
        let counter = Counter()
        let cache = makeCache(counter, delay: 0.2)
        let source = SigningKeySource.locked(ncryptsec: "ncryptsec1aaa", password: "right")
        let keys = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await cache.hexKeyOffMain(for: source) } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(keys), ["hex-of-ncryptsec1aaa"])
        XCTAssertEqual(counter.runs, 1)
    }

    func testOffMainNeverDerivesOnTheMainThread() async throws {
        let counter = Counter()
        let cache = makeCache(counter)
        let source = SigningKeySource.locked(ncryptsec: "ncryptsec1aaa", password: "right")
        let key = try await askFromMain(cache, source)
        XCTAssertEqual(key, "hex-of-ncryptsec1aaa")
        XCTAssertEqual(cache.derivations, 1)
        XCTAssertEqual(cache.mainThreadDerivations, 0)
    }

    @MainActor private func askFromMain(_ cache: SigningKeyCache, _ source: SigningKeySource) async throws -> String {
        XCTAssertTrue(Thread.isMainThread)
        return try await cache.hexKeyOffMain(for: source)
    }

    func testAMainThreadDerivationIsCounted() {
        // The gate can fail: a derivation on the main thread shows up.
        let counter = Counter()
        let cache = makeCache(counter)
        XCTAssertTrue(Thread.isMainThread)
        _ = try? cache.hexKey(for: .locked(ncryptsec: "ncryptsec1aaa", password: "right"))
        XCTAssertEqual(cache.mainThreadDerivations, 1)
    }

    func testWarmDerivesInTheBackground() async throws {
        let counter = Counter()
        let cache = makeCache(counter)
        let source = SigningKeySource.locked(ncryptsec: "ncryptsec1aaa", password: "right")
        await MainActor.run { cache.warm(source) }
        for _ in 0..<200 where cache.cachedHexKey(for: source) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(cache.cachedHexKey(for: source), "hex-of-ncryptsec1aaa")
        XCTAssertEqual(cache.mainThreadDerivations, 0)
        _ = try cache.hexKey(for: source)
        XCTAssertEqual(counter.runs, 1)
    }

    func testANewKeyIsNeverAnsweredFromTheOldEntry() throws {
        let counter = Counter()
        let cache = makeCache(counter)
        _ = try cache.hexKey(for: .locked(ncryptsec: "ncryptsec1aaa", password: "right"))
        XCTAssertEqual(try cache.hexKey(for: .locked(ncryptsec: "ncryptsec1bbb", password: "right")), "hex-of-ncryptsec1bbb")
        XCTAssertEqual(counter.runs, 2)
    }

    func testAPasswordThatNoLongerMatchesDerivesAgainAndFails() throws {
        let counter = Counter()
        let cache = makeCache(counter)
        _ = try cache.hexKey(for: .locked(ncryptsec: "ncryptsec1aaa", password: "right"))
        let changed = SigningKeySource.locked(ncryptsec: "ncryptsec1aaa", password: "other")
        XCTAssertNil(cache.cachedHexKey(for: changed))
        XCTAssertThrowsError(try cache.hexKey(for: changed))
        XCTAssertEqual(counter.runs, 2)
    }

    func testAWrongPasswordIsNotCached() {
        let counter = Counter()
        let cache = makeCache(counter)
        let wrong = SigningKeySource.locked(ncryptsec: "ncryptsec1aaa", password: "wrong")
        XCTAssertThrowsError(try cache.hexKey(for: wrong))
        XCTAssertThrowsError(try cache.hexKey(for: wrong))
        XCTAssertEqual(counter.runs, 2)
    }

    func testARemovedKeyLeavesTheCache() throws {
        let counter = Counter()
        let cache = makeCache(counter)
        let a = SigningKeySource.locked(ncryptsec: "ncryptsec1aaa", password: "right")
        let b = SigningKeySource.locked(ncryptsec: "ncryptsec1bbb", password: "right")
        _ = try cache.hexKey(for: a)
        _ = try cache.hexKey(for: b)
        cache.retainOnly(["ncryptsec1bbb"])
        XCTAssertNil(cache.cachedHexKey(for: a))
        XCTAssertNotNil(cache.cachedHexKey(for: b))
        cache.removeAll()
        XCTAssertNil(cache.cachedHexKey(for: b))
    }

    func testAPlainKeyNeedsNoDerivation() throws {
        let counter = Counter()
        let cache = makeCache(counter)
        XCTAssertEqual(try cache.hexKey(for: .plain(hex: "abc")), "abc")
        XCTAssertEqual(counter.runs, 0)
    }

    // MARK: - Where the key comes from (HavenConfig)

    func testOwnerKeySource() {
        var config = HavenConfig.default
        config.ownerNcryptsec = "  ncryptsec1owner \n"
        XCTAssertEqual(config.ownerKeySource(password: nil, storedPassword: { "kc" }),
                       .found(.locked(ncryptsec: "ncryptsec1owner", password: "kc")))
        XCTAssertEqual(config.ownerKeySource(password: "given", storedPassword: { "kc" }),
                       .found(.locked(ncryptsec: "ncryptsec1owner", password: "given")))
        XCTAssertEqual(config.ownerKeySource(password: nil, storedPassword: { nil }), .passwordMissing)

        config.ownerNcryptsec = ""
        config.ownerNsec = String(repeating: "a", count: 64)
        XCTAssertEqual(config.ownerKeySource(password: nil, storedPassword: { nil }),
                       .found(.plain(hex: String(repeating: "a", count: 64))))
        config.ownerNsec = ""
        XCTAssertEqual(config.ownerKeySource(password: nil, storedPassword: { "kc" }), .noKey)
    }

    func testCredentialKeySourceAndLockedKeyTexts() {
        var config = HavenConfig.default
        config.accountCredentials = ["npub1x": "ncryptsec1x", "npub1empty": ""]
        config.ownerNcryptsec = "ncryptsec1owner"
        XCTAssertEqual(config.credentialKeySource(forNpub: "npub1x", storedPassword: { _ in "p" }),
                       .found(.locked(ncryptsec: "ncryptsec1x", password: "p")))
        XCTAssertEqual(config.credentialKeySource(forNpub: "npub1x", storedPassword: { _ in nil }), .passwordMissing)
        XCTAssertEqual(config.credentialKeySource(forNpub: "npub1empty", storedPassword: { _ in "p" }), .noKey)
        XCTAssertEqual(config.credentialKeySource(forNpub: "npub1none", storedPassword: { _ in "p" }), .noKey)
        XCTAssertEqual(config.lockedKeyTexts, ["ncryptsec1x", "ncryptsec1owner"])
    }
}

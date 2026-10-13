import XCTest
@testable import MediaLogic

/// The owner's bunker logged in beside another active account: when it
/// starts, what a finished login leads to, and the one /chat AUTH retry.
final class OwnerSessionWarmupTests: XCTestCase {
    private let owner = "npub1owner"
    private let other = "npub1other"
    private let ownerHex = String(repeating: "a", count: 64)
    private let link = "bunker://\(String(repeating: "3", count: 64))?relay=wss://r"

    private func bunkerOwner(active: String, secret: String = "", clientSK: String = "sk") -> HavenConfig {
        var config = HavenConfig()
        config.ownerNpub = owner
        config.activeAccountNpub = active
        config.accountBunkerConfigs[owner] = AccountBunkerConfig(
            bunkerURI: link, signerPubkey: "abc", secret: secret, clientSecretKey: clientSK)
        return config
    }

    // MARK: Triggers

    /// Switching to another account (or an owner AUTH failing while one is
    /// active) starts the owner's login, with the stored link and client key.
    func testStartsWhileAnotherAccountIsActive() {
        var warmup = OwnerSessionWarmup()
        let login = warmup.start(config: bunkerOwner(active: other), ownerHex: ownerHex)
        XCTAssertEqual(login, .init(link: link, clientSecretKey: "sk", ownerHex: ownerHex))
        XCTAssertTrue(warmup.inFlight)
    }

    /// Switching back to the owner: its own connect logs it in.
    func testDoesNotStartForTheActiveOwner() {
        var warmup = OwnerSessionWarmup()
        XCTAssertNil(warmup.start(config: bunkerOwner(active: ""), ownerHex: ownerHex))
        XCTAssertNil(warmup.start(config: bunkerOwner(active: owner), ownerHex: ownerHex))
        XCTAssertFalse(warmup.inFlight)
    }

    /// A pairing still waiting on its secret must reach the signer in the
    /// foreground, where an approval can be shown.
    func testDoesNotStartWhileAPairingSecretIsPending() {
        var warmup = OwnerSessionWarmup()
        XCTAssertNil(warmup.start(config: bunkerOwner(active: other, secret: "s1"), ownerHex: ownerHex))
        var inLink = bunkerOwner(active: other)
        inLink.accountBunkerConfigs[owner]?.bunkerURI = link + "&secret=s2"
        XCTAssertNil(warmup.start(config: inLink, ownerHex: ownerHex))
        XCTAssertFalse(warmup.inFlight)
    }

    func testDoesNotStartWithoutTheOwnersClientKey() {
        var warmup = OwnerSessionWarmup()
        XCTAssertNil(warmup.start(config: bunkerOwner(active: other, clientSK: ""), ownerHex: ownerHex))
    }

    /// A burst of AUTH failures and a switch start one login, not several.
    func testOneLoginAtATime() {
        var warmup = OwnerSessionWarmup()
        let config = bunkerOwner(active: other)
        let login = warmup.start(config: config, ownerHex: ownerHex)!
        XCTAssertNil(warmup.start(config: config, ownerHex: ownerHex))
        _ = warmup.finished(login, pubkey: nil)
        XCTAssertNotNil(warmup.start(config: config, ownerHex: ownerHex))
    }

    // MARK: Finished

    func testOwnerAnsweringRetries() {
        var warmup = OwnerSessionWarmup()
        let login = warmup.start(config: bunkerOwner(active: other), ownerHex: ownerHex)!
        XCTAssertTrue(warmup.finished(login, pubkey: ownerHex))
        XCTAssertFalse(warmup.inFlight)
    }

    /// The signer answered for another account (two accounts on one signer
    /// share its session) or did not answer: nothing to retry.
    func testWrongAccountOrNoAnswerDoesNotRetry() {
        var warmup = OwnerSessionWarmup()
        let config = bunkerOwner(active: other)
        let login = warmup.start(config: config, ownerHex: ownerHex)!
        XCTAssertFalse(warmup.finished(login, pubkey: String(repeating: "b", count: 64)))
        let again = warmup.start(config: config, ownerHex: ownerHex)!
        XCTAssertFalse(warmup.finished(again, pubkey: nil))
    }

    // MARK: The /chat AUTH retry

    func testRetryFiresOnceForTheKeptChallenge() {
        var retry = PendingAuthRetry()
        retry.received("c1")
        XCTAssertTrue(retry.shouldWarmOwner())
        XCTAssertEqual(retry.takeRetry(), "c1")
        // The retry failed too: no second login, no second retry.
        XCTAssertFalse(retry.shouldWarmOwner())
        XCTAssertNil(retry.takeRetry())
    }

    /// A new socket brings a new challenge: the old one is never signed for it.
    func testRebuiltSocketDropsTheOldChallenge() {
        var retry = PendingAuthRetry()
        retry.received("c1")
        retry.reset()
        XCTAssertFalse(retry.shouldWarmOwner())
        XCTAssertNil(retry.takeRetry())
        retry.received("c2")
        XCTAssertEqual(retry.takeRetry(), "c2")
    }

    func testAcceptedAuthLeavesNothingToRetry() {
        var retry = PendingAuthRetry()
        retry.received("c1")
        retry.reset()
        XCTAssertNil(retry.takeRetry())
    }
}

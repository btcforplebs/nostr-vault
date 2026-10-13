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
        let login = warmup.start(config: bunkerOwner(active: other), ownerHex: ownerHex, activeSessionKey: nil)
        XCTAssertEqual(login, .init(link: link, clientSecretKey: "sk", ownerHex: ownerHex))
        XCTAssertTrue(warmup.inFlight)
    }

    /// Switching back to the owner: its own connect logs it in.
    func testDoesNotStartForTheActiveOwner() {
        var warmup = OwnerSessionWarmup()
        XCTAssertNil(warmup.start(config: bunkerOwner(active: ""), ownerHex: ownerHex, activeSessionKey: nil))
        XCTAssertNil(warmup.start(config: bunkerOwner(active: owner), ownerHex: ownerHex, activeSessionKey: nil))
        XCTAssertFalse(warmup.inFlight)
    }

    /// A pairing still waiting on its secret must reach the signer in the
    /// foreground, where an approval can be shown.
    func testDoesNotStartWhileAPairingSecretIsPending() {
        var warmup = OwnerSessionWarmup()
        XCTAssertNil(warmup.start(config: bunkerOwner(active: other, secret: "s1"), ownerHex: ownerHex, activeSessionKey: nil))
        var inLink = bunkerOwner(active: other)
        inLink.accountBunkerConfigs[owner]?.bunkerURI = link + "&secret=s2"
        XCTAssertNil(warmup.start(config: inLink, ownerHex: ownerHex, activeSessionKey: nil))
        XCTAssertFalse(warmup.inFlight)
    }

    func testDoesNotStartWithoutTheOwnersClientKey() {
        var warmup = OwnerSessionWarmup()
        XCTAssertNil(warmup.start(config: bunkerOwner(active: other, clientSK: ""), ownerHex: ownerHex, activeSessionKey: nil))
    }

    /// A burst of AUTH failures and a switch start one login, not several.
    func testOneLoginAtATime() {
        var warmup = OwnerSessionWarmup()
        let config = bunkerOwner(active: other)
        let login = warmup.start(config: config, ownerHex: ownerHex, activeSessionKey: nil)!
        XCTAssertNil(warmup.start(config: config, ownerHex: ownerHex, activeSessionKey: nil))
        _ = warmup.finished(login, pubkey: nil)
        XCTAssertNotNil(warmup.start(config: config, ownerHex: ownerHex, activeSessionKey: nil))
    }

    /// The owner and the active account paired to one bunker host share one
    /// Go session: a background login there would fight the active account's
    /// connect, so it never starts. A different host still does.
    func testDoesNotStartWhenTheOwnerSharesTheActiveAccountsBunker() {
        var warmup = OwnerSessionWarmup()
        let config = bunkerOwner(active: other)
        let sharedHost = String(repeating: "3", count: 64)
        XCTAssertEqual(config.ownerSessionKey, sharedHost)
        XCTAssertNil(warmup.start(config: config, ownerHex: ownerHex, activeSessionKey: sharedHost))
        XCTAssertFalse(warmup.inFlight)
        XCTAssertNotNil(warmup.start(config: config, ownerHex: ownerHex, activeSessionKey: String(repeating: "4", count: 64)))
    }

    // MARK: Signer replies

    /// A bunker reply signed by another key (a shared session answering for
    /// the other account) is never used as the account that asked.
    func testSignerReplyMustBeSignedByTheKeyAskedFor() {
        let asked = String(repeating: "a", count: 64)
        XCTAssertTrue(SignerReplyCheck.accepts(signedPubkey: asked, askedFor: asked))
        XCTAssertTrue(SignerReplyCheck.accepts(signedPubkey: asked.uppercased(), askedFor: asked))
        XCTAssertFalse(SignerReplyCheck.accepts(signedPubkey: String(repeating: "b", count: 64), askedFor: asked))
        XCTAssertFalse(SignerReplyCheck.accepts(signedPubkey: asked, askedFor: ""))
    }

    // MARK: Finished

    func testOwnerAnsweringRetries() {
        var warmup = OwnerSessionWarmup()
        let login = warmup.start(config: bunkerOwner(active: other), ownerHex: ownerHex, activeSessionKey: nil)!
        XCTAssertTrue(warmup.finished(login, pubkey: ownerHex))
        XCTAssertFalse(warmup.inFlight)
    }

    /// The signer answered for another account (two accounts on one signer
    /// share its session) or did not answer: nothing to retry.
    func testWrongAccountOrNoAnswerDoesNotRetry() {
        var warmup = OwnerSessionWarmup()
        let config = bunkerOwner(active: other)
        let login = warmup.start(config: config, ownerHex: ownerHex, activeSessionKey: nil)!
        XCTAssertFalse(warmup.finished(login, pubkey: String(repeating: "b", count: 64)))
        let again = warmup.start(config: config, ownerHex: ownerHex, activeSessionKey: nil)!
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

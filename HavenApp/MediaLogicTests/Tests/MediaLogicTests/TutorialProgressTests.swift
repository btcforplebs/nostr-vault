import XCTest
@testable import MediaLogic

private final class MemoryStore: TutorialStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) { values[key] = value }
}

final class TutorialProgressTests: XCTestCase {
    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)

    func testFillYourVaultStartsFirstAndAloneOnScreen() {
        var progress = TutorialProgress(store: MemoryStore())
        XCTAssertTrue(progress.startIfEligible(.fillYourVault, account: alice))
        XCTAssertEqual(progress.active, .fillYourVault)

        // Nothing else while it's on screen.
        XCTAssertFalse(progress.startIfEligible(.feeds, account: alice))
        XCTAssertEqual(progress.active, .fillYourVault)
    }

    /// A new account never gets a page tutorial before Fill your vault is
    /// finished or skipped.
    func testPageTutorialsWaitForFillYourVault() {
        var progress = TutorialProgress(store: MemoryStore())
        XCTAssertFalse(progress.startIfEligible(.feeds, account: alice))
        XCTAssertNil(progress.active)
    }

    /// Skipping counts the same as finishing for the gate, and every page
    /// still starts its own tutorial in the same launch, one at a time.
    func testEachPageStartsItsTutorialInTheSameLaunch() {
        var progress = TutorialProgress(store: MemoryStore())
        progress.startIfEligible(.fillYourVault, account: alice)
        progress.skip(.fillYourVault, account: alice)
        XCTAssertNil(progress.active)
        XCTAssertTrue(progress.startIfEligible(.feeds, account: alice))
        XCTAssertFalse(progress.startIfEligible(.vault, account: alice))

        progress.skip(.feeds, account: alice)
        XCTAssertTrue(progress.startIfEligible(.vault, account: alice))
        XCTAssertEqual(progress.active, .vault)
    }

    /// Fill your vault's "built" card is up after it's done: nothing starts
    /// over it until it's put away.
    func testHeldStopsPageTutorials() {
        var progress = TutorialProgress(store: MemoryStore())
        progress.startIfEligible(.fillYourVault, account: alice)
        progress.finish(.fillYourVault, account: alice)
        progress.held = true
        XCTAssertFalse(progress.startIfEligible(.feeds, account: alice))

        progress.held = false
        XCTAssertTrue(progress.startIfEligible(.feeds, account: alice))
    }

    func testFinishedTutorialNeverStartsAgainOnItsOwn() {
        let store = MemoryStore()
        var progress = TutorialProgress(store: store)
        progress.startIfEligible(.fillYourVault, account: alice)
        progress.finish(.fillYourVault, account: alice)
        XCTAssertEqual(progress.status(.fillYourVault, account: alice), .done)

        var nextLaunch = TutorialProgress(store: store)
        XCTAssertFalse(nextLaunch.startIfEligible(.fillYourVault, account: alice))
    }

    /// Fill your vault is about one account's follows; the page tutorials
    /// teach the app, so they're shared by every account on the device.
    func testScopes() {
        let store = MemoryStore()
        var progress = TutorialProgress(store: store)
        progress.finish(.fillYourVault, account: alice)
        progress.finish(.feeds, account: alice)

        XCTAssertEqual(progress.status(.fillYourVault, account: bob), .notStarted)
        XCTAssertEqual(progress.status(.feeds, account: bob), .done)

        var nextLaunch = TutorialProgress(store: store)
        XCTAssertTrue(nextLaunch.startIfEligible(.fillYourVault, account: bob))
    }

    func testReplayShowsAFinishedTutorialAndKeepsItsStatus() {
        var progress = TutorialProgress(store: MemoryStore())
        progress.finish(.fillYourVault, account: alice)
        progress.finish(.feeds, account: alice)

        progress.replay(.feeds)
        XCTAssertEqual(progress.active, .feeds)
        XCTAssertEqual(progress.status(.feeds, account: alice), .done)
    }

    /// Closing a tutorial that isn't the one on screen saves its status but
    /// leaves the other one up.
    func testClosingAnotherTutorialLeavesTheActiveOne() {
        var progress = TutorialProgress(store: MemoryStore())
        progress.startIfEligible(.fillYourVault, account: alice)
        progress.finish(.feeds, account: alice)
        XCTAssertEqual(progress.active, .fillYourVault)
        XCTAssertEqual(progress.status(.feeds, account: alice), .done)
    }

    func testResetAllShowsEverythingAgain() {
        let store = MemoryStore()
        var progress = TutorialProgress(store: store)
        progress.finish(.fillYourVault, account: alice)
        progress.skip(.feeds, account: alice)
        progress.resetAll(account: alice)
        XCTAssertTrue(TutorialID.allCases.allSatisfy { progress.status($0, account: alice) == .notStarted })
    }

    /// No account yet (still in setup): nothing starts and nothing is saved
    /// under an empty key.
    func testNoAccountDoesNothing() {
        let store = MemoryStore()
        var progress = TutorialProgress(store: store)
        XCTAssertFalse(progress.startIfEligible(.fillYourVault, account: ""))
        progress.finish(.feeds, account: "")
        XCTAssertTrue(store.values.isEmpty)
    }

    /// Stored values from another version, or garbage, read as not started.
    func testOtherVersionsReadAsNotStarted() {
        let store = MemoryStore()
        let progress = TutorialProgress(store: store)
        let key = TutorialProgress.key(.feeds, account: alice)

        store.values[key] = "done@\(TutorialID.feeds.version)"
        XCTAssertEqual(progress.status(.feeds, account: alice), .done)
        store.values[key] = "done@\(TutorialID.feeds.version + 1)"
        XCTAssertEqual(progress.status(.feeds, account: alice), .notStarted)
        store.values[key] = "done"
        XCTAssertEqual(progress.status(.feeds, account: alice), .notStarted)
    }

    /// Storage keys are the raw values: renaming one would show it again to
    /// everyone who has seen it.
    func testStorageKeysAreStable() {
        XCTAssertEqual(TutorialProgress.key(.fillYourVault, account: alice), "tutorial.fill-your-vault.\(alice)")
        XCTAssertEqual(TutorialProgress.key(.feeds, account: alice), "tutorial.feeds")
        XCTAssertEqual(TutorialProgress.key(.walletConnect, account: alice), "tutorial.wallet-connect")
        XCTAssertEqual(TutorialProgress.key(.pocketRelay, account: alice), "tutorial.pocket-relay")
    }

    func testFeedsCardsPointAtTheTwoCorners() {
        XCTAssertEqual(TutorialContent.feeds.map(\.anchor), [
            TutorialContent.feedPicker, TutorialContent.feedToolbar, TutorialContent.feedToolbar,
        ])
    }

    /// Vault in Your Pocket points at the relay card, its activity, then its
    /// address.
    func testPocketRelayCardsPointAtTheDashboard() {
        XCTAssertEqual(TutorialContent.pocketRelay.map(\.anchor), [
            TutorialContent.relayStatus, TutorialContent.relayActivity, TutorialContent.relayAddress,
        ])
    }

    /// The vault is a personal relay and media server, not a "pocket relay"
    /// (nostr-vault Tutorial thread 2026-10-09).
    func testNoCopySaysPocketRelay() {
        for id in TutorialID.allCases {
            let text = ([id.title, id.summary] + id.steps.flatMap { [$0.title, $0.body] })
                .joined(separator: " ").lowercased()
            XCTAssertFalse(text.contains("pocket relay"), "\(id)")
        }
    }

    /// Only a tutorial that can run is offered as next, so the last card
    /// never starts one with nothing to draw.
    func testNextSkipsTutorialsWithoutCards() {
        #if os(iOS)
        XCTAssertEqual(TutorialID.feeds.next, .vault)
        #else
        XCTAssertNil(TutorialID.feeds.next)
        #endif
        #if os(iOS)
        XCTAssertEqual(TutorialID.vault.next, .pocketRelay)
        XCTAssertEqual(TutorialID.pocketRelay.next, .walletConnect)
        #else
        XCTAssertNil(TutorialID.vault.next)
        XCTAssertNil(TutorialID.pocketRelay.next)
        #endif
        XCTAssertNil(TutorialID.walletConnect.next)
        XCTAssertNil(TutorialID.importTour.next)
        // Fill your feed's last card opens Discover and starts Feeds.
        #if os(iOS)
        XCTAssertEqual(TutorialID.fillYourVault.next, .feeds)
        #else
        XCTAssertNil(TutorialID.fillYourVault.next)
        #endif
    }

    /// The import tour teaches Vault and Pocket relay, so finishing it marks
    /// those done. Skipping it (keep running, jump in early) doesn't.
    func testImportTourCoversVaultAndPocketRelay() {
        var progress = TutorialProgress(store: MemoryStore())
        progress.skip(.importTour, account: alice)
        XCTAssertEqual(progress.status(.vault, account: alice), .notStarted)

        progress.finish(.importTour, account: alice)
        XCTAssertEqual(progress.status(.vault, account: alice), .done)
        XCTAssertEqual(progress.status(.pocketRelay, account: alice), .done)
    }

    /// Covering never overwrites a status someone already chose.
    func testCoverKeepsAnEarlierSkip() {
        var progress = TutorialProgress(store: MemoryStore())
        progress.skip(.vault, account: alice)
        progress.finish(.importTour, account: alice)
        XCTAssertEqual(progress.status(.vault, account: alice), .skipped)
    }

    /// The import tour runs in setup, before Fill your vault has a say.
    func testImportTourDoesNotWaitForFillYourVault() {
        var progress = TutorialProgress(store: MemoryStore())
        XCTAssertTrue(progress.startIfEligible(.importTour, account: alice))
    }

    func testImportTourKey() {
        XCTAssertEqual(TutorialProgress.key(.importTour, account: alice), "tutorial.import-tour")
        XCTAssertEqual(TutorialContent.importTour.count, 5)
        XCTAssertTrue(TutorialContent.importTour.allSatisfy { $0.anchor == nil })
    }
}

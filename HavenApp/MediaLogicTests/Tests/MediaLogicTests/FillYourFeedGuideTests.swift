import XCTest
@testable import MediaLogic

private final class DictStore: TutorialStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) { values[key] = value }
}

final class FillYourFeedGuideTests: XCTestCase {

    private func meter(_ n: Int, earned: Bool = false) -> VaultMeter {
        VaultMeter(follows: (0..<n).map { "p\($0)" }, owner: "me", masterEarned: earned)
    }

    func testEntryResumesOnTheFeedOnceTheMeterIsOn() {
        XCTAssertEqual(FillYourFeedGuide.entryPhase(meterOn: false), .intro)
        XCTAssertEqual(FillYourFeedGuide.entryPhase(meterOn: true), .browsing)
    }

    func testMeterHiddenDuringIntroAndTopicsAndWhenOff() {
        XCTAssertFalse(FillYourFeedGuide.showsMeter(phase: .intro, meterOn: true))
        XCTAssertFalse(FillYourFeedGuide.showsMeter(phase: .topics, meterOn: true))
        for phase: FillYourFeedPhase in [.off, .hint, .browsing, .ready] {
            XCTAssertTrue(FillYourFeedGuide.showsMeter(phase: phase, meterOn: true), "\(phase)")
            XCTAssertFalse(FillYourFeedGuide.showsMeter(phase: phase, meterOn: false), "\(phase)")
        }
    }

    func testShowPostsButton() {
        XCTAssertEqual(FillYourFeedGuide.showPostsTitle(selected: 0), "Pick at least one")
        XCTAssertEqual(FillYourFeedGuide.showPostsTitle(selected: 3), "Show posts (3)")
    }

    func testMeterTextsAcrossStages() {
        XCTAssertEqual(FillYourFeedGuide.meterTitle(meter(3), compact: false), "3 of 5")
        XCTAssertEqual(FillYourFeedGuide.meterTitle(meter(3), compact: true), "3/5")
        XCTAssertEqual(FillYourFeedGuide.meterSubtitle(meter(3)), "2 more to go")
        XCTAssertEqual(FillYourFeedGuide.meterSubtitle(meter(0)), "5 more to go")
        XCTAssertEqual(FillYourFeedGuide.meterSubtitle(meter(4)), "1 more to go")
        XCTAssertEqual(FillYourFeedGuide.pillText(meter(3)), "3/5")
        XCTAssertEqual(FillYourFeedGuide.meterTitle(meter(5), compact: false), "Web of trust")
        XCTAssertEqual(FillYourFeedGuide.meterSubtitle(meter(5)), "5 people followed")
        XCTAssertEqual(FillYourFeedGuide.pillText(meter(5)), "Web of trust")
    }

    func testEarnedMasterStaysGoldBelowFive() {
        let m = meter(3, earned: true)
        XCTAssertEqual(FillYourFeedGuide.pillText(m), "Web of trust")
        XCTAssertEqual(FillYourFeedGuide.ringFraction(m), 1)
        XCTAssertEqual(FillYourFeedGuide.ringFraction(meter(2)), 0.4, accuracy: 0.0001)
    }

    func testMeterStoreIsPerAccountAndIgnoresBlankAccount() {
        let store = FeedMeterStore(store: DictStore())
        XCTAssertFalse(store.isOn(account: "a"))
        store.set(true, account: "a")
        XCTAssertTrue(store.isOn(account: "a"))
        XCTAssertFalse(store.isOn(account: "b"))
        store.set(false, account: "a")
        XCTAssertFalse(store.isOn(account: "a"))
        store.set(true, account: "")
        XCTAssertFalse(store.isOn(account: ""))
    }

    func testGuideIsAvailableSoSettingsCanReplayIt() {
        XCTAssertTrue(TutorialID.fillYourVault.isAvailable)
        XCTAssertEqual(TutorialID.fillYourVault.title, "Fill Your Feed")
    }

    /// Logen 2026-11-26 70edd8f4: nobody with a follow list under 5 lands on #.
    func testLetsFillItOpensTopicsOnlyForAKeyThatFollowsNobody() {
        XCTAssertEqual(FillYourFeedGuide.afterIntro(follows: 0), .topics)
        for count in 1...4 { XCTAssertEqual(FillYourFeedGuide.afterIntro(follows: count), .browsing, "\(count)") }
        XCTAssertEqual(FillYourFeedGuide.afterIntro(follows: 5), .browsing)
    }

    func testAFailedTopicSaveSaysWhy() {
        XCTAssertTrue(FillYourFeedGuide.topicSaveFailedText(noRelayList: true).contains("relay list"))
        XCTAssertTrue(FillYourFeedGuide.topicSaveFailedText(noRelayList: false).contains("relays answered"))
        XCTAssertNotEqual(FillYourFeedGuide.retryTopicsTitle, FillYourFeedGuide.showPostsTitle(selected: 1))
    }

    // MARK: New account: 5 follows before the guide can be left

    func testNewAccountCannotLeaveBeforeFive() {
        for count in 0..<5 {
            XCTAssertFalse(FillYourFeedGuide.canLeave(required: true, count: count), "\(count)")
        }
        XCTAssertTrue(FillYourFeedGuide.canLeave(required: true, count: 5))
        XCTAssertTrue(FillYourFeedGuide.canLeave(required: true, count: 9))
    }

    func testExistingAccountsKeepTheirWayOut() {
        for count in [0, 1, 4, 5, 40] {
            XCTAssertTrue(FillYourFeedGuide.canLeave(required: false, count: count), "\(count)")
        }
    }

    func testRequiredIsPerAccountAndOffByDefault() {
        let store = FeedGuideRequiredStore(store: DictStore())
        XCTAssertFalse(store.isRequired(account: "old"))
        store.set(true, account: "new")
        XCTAssertTrue(store.isRequired(account: "new"))
        XCTAssertFalse(store.isRequired(account: "old"))
        XCTAssertFalse(store.isRequired(account: ""))
        store.set(false, account: "new")
        XCTAssertFalse(store.isRequired(account: "new"))
    }
}

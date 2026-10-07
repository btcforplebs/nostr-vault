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
        for phase: FillYourFeedPhase in [.off, .hint, .browsing, .ready, .master] {
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
        XCTAssertEqual(FillYourFeedGuide.meterSubtitle(meter(3)), "Look before you follow")
        XCTAssertEqual(FillYourFeedGuide.meterTitle(meter(7), compact: false), "7 of 10")
        XCTAssertEqual(FillYourFeedGuide.meterSubtitle(meter(7)), "10 = Vault Master")
        XCTAssertEqual(FillYourFeedGuide.pillText(meter(7)), "7/10")
        XCTAssertEqual(FillYourFeedGuide.meterTitle(meter(10), compact: true), "Vault Master")
        XCTAssertEqual(FillYourFeedGuide.pillText(meter(10)), "Vault Master")
    }

    func testEarnedMasterStaysGoldBelowTen() {
        let m = meter(8, earned: true)
        XCTAssertEqual(FillYourFeedGuide.pillText(m), "Vault Master")
        XCTAssertEqual(FillYourFeedGuide.ringFraction(m), 1)
        XCTAssertEqual(FillYourFeedGuide.ringFraction(meter(4)), 0.4, accuracy: 0.0001)
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
}

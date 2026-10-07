import XCTest
@testable import MediaLogic

final class VaultMeterTests: XCTestCase {

    private let owner = "owner"
    private func people(_ n: Int) -> [String] { (1...max(n, 1)).prefix(n).map { "p\($0)" } }

    func testOwnerIsNotAFollow() {
        let meter = VaultMeter(follows: [owner, "p1", "p2"], owner: owner, masterEarned: false)
        XCTAssertEqual(meter.count, 2)
        XCTAssertEqual(meter.recent, ["p1", "p2"])
    }

    func testDuplicatesAndBlanksCountOnce() {
        let meter = VaultMeter(follows: ["p1", "", "p1", "p2"], owner: owner, masterEarned: false)
        XCTAssertEqual(meter.count, 2)
    }

    func testStagesAtFiveAndTen() {
        XCTAssertEqual(VaultMeter(follows: people(4), owner: owner, masterEarned: false).stage, .filling)
        XCTAssertEqual(VaultMeter(follows: people(5), owner: owner, masterEarned: false).stage, .filled)
        XCTAssertEqual(VaultMeter(follows: people(9), owner: owner, masterEarned: false).stage, .filled)
        XCTAssertEqual(VaultMeter(follows: people(10), owner: owner, masterEarned: false).stage, .master)
    }

    // Gold is a lasting mark: dropping below 10 afterwards keeps it.
    func testEarnedMasterSurvivesAnUnfollow() {
        XCTAssertEqual(VaultMeter(follows: people(8), owner: owner, masterEarned: true).stage, .master)
    }

    func testProgressTextSwitchesRowsAtFive() {
        XCTAssertEqual(VaultMeter(follows: people(3), owner: owner, masterEarned: false).progressText, "3 of 5")
        XCTAssertEqual(VaultMeter(follows: people(7), owner: owner, masterEarned: false).progressText, "7 of 10")
        XCTAssertEqual(VaultMeter(follows: people(14), owner: owner, masterEarned: false).progressText, "10 of 10")
        XCTAssertEqual(VaultMeter(follows: people(4), owner: owner, masterEarned: false).compactProgressText, "4/5")
    }

    func testAccessibilityText() {
        XCTAssertEqual(VaultMeter(follows: people(1), owner: owner, masterEarned: false).accessibilityText,
                       "1 of 5 person followed.")
        XCTAssertEqual(VaultMeter(follows: people(4), owner: owner, masterEarned: false).accessibilityText,
                       "4 of 5 people followed.")
        XCTAssertEqual(VaultMeter(follows: people(10), owner: owner, masterEarned: false).accessibilityText,
                       "Vault Master. 10 of 10 people followed.")
    }

    func testRecentKeepsTheNewestTen() {
        let meter = VaultMeter(follows: people(12), owner: owner, masterEarned: false)
        XCTAssertEqual(meter.recent.first, "p3")
        XCTAssertEqual(meter.recent.last, "p12")
        XCTAssertEqual(meter.recent.count, 10)
    }

    func testFiveOrMoreSkipsTheGuide() {
        XCTAssertFalse(VaultMeter.skipsGuide(followCount: 4))
        XCTAssertTrue(VaultMeter.skipsGuide(followCount: 5))
    }

    func testCelebrationFiresOncePerAccount() {
        let defaults = UserDefaults(suiteName: "VaultMeterTests.\(UUID().uuidString)")!
        let store = VaultMasterStore(defaults: defaults)
        let nine = VaultMeter(follows: people(9), owner: owner, masterEarned: false)
        let ten = VaultMeter(follows: people(10), owner: owner, masterEarned: false)

        XCTAssertFalse(store.record(nine, owner: owner))
        XCTAssertFalse(store.isEarned(owner: owner))
        XCTAssertTrue(store.record(ten, owner: owner))
        XCTAssertFalse(store.record(ten, owner: owner), "the bolt must play only once")
        XCTAssertTrue(store.isEarned(owner: owner))
        XCTAssertFalse(store.isEarned(owner: "someone-else"), "earned is per account")
        XCTAssertFalse(store.record(ten, owner: ""), "no account, nothing to record")
    }

    func testTopicLists() {
        XCTAssertEqual(VaultTopics.starter.count, 20)
        XCTAssertEqual(Set(VaultTopics.starter).count, 20)
        XCTAssertTrue(Set(VaultTopics.more).isDisjoint(with: VaultTopics.starter))
        XCTAssertEqual(Set(VaultTopics.more).count, VaultTopics.more.count)
        for tag in VaultTopics.starter + VaultTopics.more {
            XCTAssertEqual(VaultTopics.normalize(tag), tag, "\(tag) is not already normalised")
        }
    }

    func testTypedHashtagIsNormalised() {
        XCTAssertEqual(VaultTopics.normalize("  #Bitcoin "), "bitcoin")
        XCTAssertEqual(VaultTopics.normalize("##Self Hosting"), "selfhosting")
        XCTAssertNil(VaultTopics.normalize(" # "))
    }
}

final class FillYourVaultRuleTests: XCTestCase {
    private func act(known: Bool = true, prev: Int? = nil, _ count: Int,
                     _ status: TutorialStatus = .notStarted, active: Bool = false) -> FillYourVaultRule.Action {
        FillYourVaultRule.onFollowsChanged(listKnown: known, previousCount: prev, count: count,
                                           status: status, isActive: active)
    }

    // The count reads 0 for everyone until the list loads.
    func testNothingHappensBeforeTheFollowListLoads() {
        XCTAssertEqual(act(known: false, 0), .none)
        XCTAssertEqual(act(known: false, 300), .none)
    }

    func testNewAccountStartsTheGuide() {
        XCTAssertEqual(act(0), .start)
        XCTAssertEqual(act(4), .start)
    }

    // Page tutorials wait for Fill your vault, so established accounts must
    // be marked done or they never see them.
    func testEstablishedAccountIsFinishedSilently() {
        XCTAssertEqual(act(5), .finishSilently)
        XCTAssertEqual(act(300), .finishSilently)
    }

    func testDecidedOnceOnly() {
        XCTAssertEqual(act(0, .skipped), .none)
        XCTAssertEqual(act(300, .done), .none)
    }

    func testCrossingFiveWhileShowingFinishes() {
        XCTAssertEqual(act(prev: 4, 5, active: true), .finish)
        XCTAssertEqual(act(prev: 3, 4, active: true), .none)
    }

    // A replay opened past 5 stays up so the person can go for 10.
    func testReplayPastFiveStaysOpen() {
        XCTAssertEqual(act(prev: nil, 7, .done, active: true), .none)
        XCTAssertEqual(act(prev: 7, 8, .done, active: true), .none)
    }

    func testClosingByHand() {
        XCTAssertEqual(FillYourVaultRule.onClose(count: 2), .skipped)
        XCTAssertEqual(FillYourVaultRule.onClose(count: 7), .done)
    }
}

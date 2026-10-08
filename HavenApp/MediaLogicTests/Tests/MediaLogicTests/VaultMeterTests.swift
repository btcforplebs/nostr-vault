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

    // Five builds the web of trust; there is no second goal.
    func testWebOfTrustIsBuiltAtFive() {
        XCTAssertEqual(VaultMeter(follows: people(4), owner: owner, masterEarned: false).stage, .filling)
        XCTAssertEqual(VaultMeter(follows: people(5), owner: owner, masterEarned: false).stage, .master)
        XCTAssertEqual(VaultMeter(follows: people(12), owner: owner, masterEarned: false).stage, .master)
    }

    // Gold is a lasting mark: dropping below 5 afterwards keeps it.
    func testEarnedMasterSurvivesAnUnfollow() {
        XCTAssertEqual(VaultMeter(follows: people(3), owner: owner, masterEarned: true).stage, .master)
    }

    func testProgressTextStaysOnFive() {
        XCTAssertEqual(VaultMeter(follows: people(3), owner: owner, masterEarned: false).progressText, "3 of 5")
        XCTAssertEqual(VaultMeter(follows: people(7), owner: owner, masterEarned: false).progressText, "5 of 5")
        XCTAssertEqual(VaultMeter(follows: people(4), owner: owner, masterEarned: false).compactProgressText, "4/5")
    }

    func testAccessibilityText() {
        XCTAssertEqual(VaultMeter(follows: people(1), owner: owner, masterEarned: false).accessibilityText,
                       "1 of 5 person followed.")
        XCTAssertEqual(VaultMeter(follows: people(4), owner: owner, masterEarned: false).accessibilityText,
                       "4 of 5 people followed.")
        XCTAssertEqual(VaultMeter(follows: people(5), owner: owner, masterEarned: false).accessibilityText,
                       "Web of trust built. 5 of 5 people followed.")
    }

    func testRecentKeepsTheNewestFive() {
        let meter = VaultMeter(follows: people(12), owner: owner, masterEarned: false)
        XCTAssertEqual(meter.recent.first, "p8")
        XCTAssertEqual(meter.recent.last, "p12")
        XCTAssertEqual(meter.recent.count, 5)
    }

    func testFiveOrMoreSkipsTheGuide() {
        XCTAssertFalse(VaultMeter.skipsGuide(followCount: 4))
        XCTAssertTrue(VaultMeter.skipsGuide(followCount: 5))
    }

    func testCelebrationFiresOncePerAccount() {
        let defaults = UserDefaults(suiteName: "VaultMeterTests.\(UUID().uuidString)")!
        let store = VaultMasterStore(defaults: defaults)
        let four = VaultMeter(follows: people(4), owner: owner, masterEarned: false)
        let five = VaultMeter(follows: people(5), owner: owner, masterEarned: false)

        XCTAssertFalse(store.record(four, owner: owner))
        XCTAssertFalse(store.isEarned(owner: owner))
        XCTAssertTrue(store.record(five, owner: owner))
        XCTAssertFalse(store.record(five, owner: owner), "the bolt must play only once")
        XCTAssertTrue(store.isEarned(owner: owner))
        XCTAssertFalse(store.isEarned(owner: "someone-else"), "earned is per account")
        XCTAssertFalse(store.record(five, owner: ""), "no account, nothing to record")
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

    // A replay opened past 5 stays up until the person closes it.
    func testReplayPastFiveStaysOpen() {
        XCTAssertEqual(act(prev: nil, 7, .done, active: true), .none)
        XCTAssertEqual(act(prev: 7, 8, .done, active: true), .none)
    }

    func testClosingByHand() {
        XCTAssertEqual(FillYourVaultRule.onClose(count: 2), .skipped)
        XCTAssertEqual(FillYourVaultRule.onClose(count: 7), .done)
    }
}

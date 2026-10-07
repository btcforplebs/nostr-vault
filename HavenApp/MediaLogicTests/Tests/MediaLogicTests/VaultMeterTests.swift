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

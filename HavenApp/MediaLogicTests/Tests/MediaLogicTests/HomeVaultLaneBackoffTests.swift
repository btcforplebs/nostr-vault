import XCTest
@testable import MediaLogic

/// Phone-to-device lanes retry within about 2 minutes and right away when the
/// device comes into reach; the always-on home vault keeps its long backoff
/// (Logen 2026-11-13: a photo waited 32 min for a device that was closed).
final class HomeVaultLaneBackoffTests: XCTestCase {
    private let home = "npub1home"
    private let phone = "npub1phone"
    private let mac = "npub1mac"

    private func item(_ kind: HomeVaultItem.Kind = .blob, target: String? = nil, attempts: Int = 0,
                      notBefore: Date? = nil, added: Date = Date()) -> HomeVaultItem {
        HomeVaultItem(kind: kind, id: "b\(attempts)", ownerHex: "aa", eventJSON: nil, contentType: nil,
                      added: added, attempts: attempts, notBefore: notBefore, target: target)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Tron M1 (#2005): the 2-min wait is only for a device that is out of reach.
    func testUnreachedLaneRetriesWithinTwoMinutes() {
        var it = item(target: phone)
        for _ in 0..<30 { it = HomeVaultLogic.afterRetry(it, lane: true, reached: false, now: t0) }
        XCTAssertEqual(it.notBefore, t0.addingTimeInterval(120))
        XCTAssertEqual(it.attempts, 30)
        XCTAssertEqual(it.answered ?? 0, 0, "a try that never reached the device is not an answer")
    }

    func testAnsweredLaneTriesGoBackToTheLongBackoff() {
        var it = item(target: phone)
        for _ in 0..<6 { it = HomeVaultLogic.afterRetry(it, lane: true, reached: true, now: t0) }
        XCTAssertEqual(it.notBefore, t0.addingTimeInterval(32 * 60), "1 min doubling, as before #2005")
        for _ in 0..<20 { it = HomeVaultLogic.afterRetry(it, lane: true, reached: true, now: t0) }
        XCTAssertEqual(it.notBefore, t0.addingTimeInterval(6 * 3600), "up to 6 h")
    }

    func testUnreachedTriesDoNotInflateTheAnsweredBackoff() {
        var it = item(target: phone)
        for _ in 0..<50 { it = HomeVaultLogic.afterRetry(it, lane: true, reached: false, now: t0) }
        it = HomeVaultLogic.afterRetry(it, lane: true, reached: true, now: t0)
        XCTAssertEqual(it.notBefore, t0.addingTimeInterval(60), "the first answered try waits 1 min")
    }

    func testHomeVaultKeepsItsBackoff() {
        var it = item()
        for _ in 0..<6 { it = HomeVaultLogic.afterRetry(it, lane: false, reached: false, now: t0) }
        XCTAssertEqual(it.notBefore, t0.addingTimeInterval(32 * 60))
        XCTAssertEqual(it.attempts, 6)
    }

    func testOnlyTheHomeVaultIsNotALane() {
        XCTAssertFalse(HomeVaultLogic.isLane(item(), homeVault: home, mediaVault: home))
        XCTAssertFalse(HomeVaultLogic.isLane(item(target: home), homeVault: home, mediaVault: home))
        XCTAssertTrue(HomeVaultLogic.isLane(item(target: phone), homeVault: home, mediaVault: home))
        XCTAssertTrue(HomeVaultLogic.isLane(item(), homeVault: nil, mediaVault: mac), "media to the Mac with no kiosk is a lane")
        XCTAssertFalse(HomeVaultLogic.isLane(item(.mirror), homeVault: nil, mediaVault: mac), "a public copy is not a device lane")
        XCTAssertFalse(HomeVaultLogic.isLane(item(.event), homeVault: home, mediaVault: mac), "notes go to the kiosk")
    }

    /// Tron L1 (#2005): media to the Mac is a lane with a kiosk too, as on Android (role MAC).
    func testMediaToTheMacIsALaneWithAKioskToo() {
        XCTAssertTrue(HomeVaultLogic.isLane(item(), homeVault: home, mediaVault: mac))
    }

    func testDestinationFollowsTheLane() {
        XCTAssertEqual(HomeVaultLogic.destination(item(target: phone), homeVault: home, mediaVault: home), phone)
        XCTAssertEqual(HomeVaultLogic.destination(item(), homeVault: nil, mediaVault: mac), mac)
        XCTAssertEqual(HomeVaultLogic.destination(item(.event), homeVault: nil, mediaVault: mac), nil, "notes go to a kiosk only")
    }

    func testLaneGivesUpAfterFortyAnsweredTriesOrOnAge() {
        let now = Date(timeIntervalSince1970: 100 * 86400)
        var it = item(target: phone, attempts: 400, added: now)
        XCTAssertFalse(HomeVaultLogic.isExpired(it, now: now, lane: true),
                       "tries that never reached the device do not count toward 40")
        it.answered = 40
        XCTAssertTrue(HomeVaultLogic.isExpired(it, now: now, lane: true), "40 answered tries: give up, as before #2005")
        XCTAssertTrue(HomeVaultLogic.isExpired(item(target: phone, attempts: 1, added: now.addingTimeInterval(-15 * 86400)), now: now, lane: true))
        XCTAssertTrue(HomeVaultLogic.isExpired(item(attempts: 40, added: now), now: now, lane: false))
    }

    func testDeviceComingIntoReachWakesItsWaitingItems() {
        let later = Date().addingTimeInterval(600)
        let queue = [item(target: phone, attempts: 3, notBefore: later),
                     item(target: mac, attempts: 4, notBefore: later),
                     item(attempts: 5, notBefore: later)]
        let woke = HomeVaultLogic.wakeOnReach(queue, newlyInReach: [phone, home], homeVault: home, mediaVault: home)
        XCTAssertEqual(woke.map(\.notBefore), [nil, later, later], "only the lane whose device came into reach, never the home vault")
        XCTAssertEqual(woke.map(\.attempts), [3, 4, 5])
    }

    func testNewlyInReachIsOnlyWhatJustConnected() {
        XCTAssertEqual(HomeVaultLogic.newlyInReach(now: [phone, mac], before: [mac]), [phone])
        XCTAssertEqual(HomeVaultLogic.newlyInReach(now: [mac], before: [mac, phone]), [])
    }
}

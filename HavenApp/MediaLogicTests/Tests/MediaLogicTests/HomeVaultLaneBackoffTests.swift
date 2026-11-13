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

    func testLaneBackoffIsCappedAtTwoMinutes() {
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 1, lane: true), 60)
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 2, lane: true), 120)
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 6, lane: true), 120)
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 30, lane: true), 120)
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 6, lane: false), 32 * 60, "the home vault keeps its backoff")
    }

    func testOnlyTheHomeVaultIsNotALane() {
        XCTAssertFalse(HomeVaultLogic.isLane(item(), homeVault: home))
        XCTAssertFalse(HomeVaultLogic.isLane(item(target: home), homeVault: home))
        XCTAssertTrue(HomeVaultLogic.isLane(item(target: phone), homeVault: home))
        XCTAssertTrue(HomeVaultLogic.isLane(item(), homeVault: nil), "media to the Mac with no kiosk is a lane")
        XCTAssertFalse(HomeVaultLogic.isLane(item(.mirror), homeVault: nil), "a public copy is not a device lane")
    }

    func testDestinationFollowsTheLane() {
        XCTAssertEqual(HomeVaultLogic.destination(item(target: phone), homeVault: home, mediaVault: home), phone)
        XCTAssertEqual(HomeVaultLogic.destination(item(), homeVault: nil, mediaVault: mac), mac)
        XCTAssertEqual(HomeVaultLogic.destination(item(.event), homeVault: nil, mediaVault: mac), nil, "notes go to a kiosk only")
    }

    func testLaneItemsDoNotGiveUpOnTriesOnlyOnAge() {
        let now = Date(timeIntervalSince1970: 100 * 86400)
        XCTAssertFalse(HomeVaultLogic.isExpired(item(target: phone, attempts: 400, added: now), now: now, lane: true),
                       "2-min tries would give up on a photo after ~80 min")
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

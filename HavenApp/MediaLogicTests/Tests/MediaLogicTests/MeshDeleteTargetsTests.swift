import XCTest
@testable import MediaLogic

/// Delete everywhere on iOS/Mac reaches the owner's mesh devices over the
/// mesh and never sends an HTTP delete to a `.fips` name (RESEARCH
/// NV_MIRROR_DELETE_ANDROID_VS_IOS #6). Builds lists only: nothing is sent.
final class MeshDeleteTargetsTests: XCTestCase {
    /// Address-shaped strings, not keys.
    private let own = "npub1throwawayownphone"
    private let home = "npub1throwawayhomevault"
    private let mac = "npub1throwawaystudiomac"
    private let phone = "npub1throwawayotherphone"
    private let browser = "npub1throwawaybrowser"
    private let blob = String(repeating: "cd", count: 32)

    private var devices: [MeshDevice] {
        [MeshDevice(npub: phone, name: "", role: .phone),
         MeshDevice(npub: mac, name: "Studio Mac", role: .mac),
         MeshDevice(npub: browser, name: "", role: .browser),
         MeshDevice(npub: own, name: "", role: .phone),
         MeshDevice(npub: home, name: "", role: .homeVault)]
    }

    func testEverywhereReachesHomeVaultMacAndPhonesNotSelfOrBrowser() {
        let targets = MeshDeleteTargets.of(devices: devices, ownNpub: own, includeHomeVault: true)
        XCTAssertEqual(targets.map(\.npub), [home, mac, phone])
        XCTAssertEqual(targets.map(\.name), ["the mobile vault", "Studio Mac", "your other phone"])
        XCTAssertEqual(targets.first?.key, "fipsmesh://\(home)/")
    }

    func testMediaServersOnlyKeepsEveryDeviceCopy() {
        XCTAssertEqual(MeshDeleteTargets.of(devices: devices, ownNpub: own, includeHomeVault: false), [])
    }

    /// With FIPS publish on, Delete everywhere used to DELETE the device's own
    /// `npub….fips` over the ordinary session: a DNS leak and a false
    /// "Still on npub….fips". No mesh address is an HTTP target any more.
    func testFipsAddressIsNeverAnHTTPTarget() {
        var config = HavenConfig()
        config.blossomMirrors = ["https://blossom.primal.net"]
        config.fipsPublishEnabled = true
        config.fipsAddressSource = "custom"
        config.fipsCustomNpub = own
        let targets = config.blossomDeleteTargets(
            ownerServerList: ["fipsmesh://\(home)/", "http://\(mac).fips:3355"],
            photoURL: nil, includeHomeVault: true)
        XCTAssertEqual(targets, ["https://blossom.primal.net"])
        XCTAssertFalse(targets.contains { $0.contains(".fips") || $0.hasPrefix("fipsmesh") })
    }

    /// A device that does not list this one answers 404 on its mesh door, which
    /// has no DELETE: only a HEAD 404 after the DELETE proves it gone.
    func testGoneNeedsTheHeadToSay404() {
        XCTAssertTrue(MeshDeleteTargets.gone(deleteStatus: 200, checkStatus: 404))
        XCTAssertTrue(MeshDeleteTargets.gone(deleteStatus: 404, checkStatus: 404))
        XCTAssertFalse(MeshDeleteTargets.gone(deleteStatus: 404, checkStatus: 200))
        XCTAssertFalse(MeshDeleteTargets.gone(deleteStatus: 200, checkStatus: nil))
        XCTAssertFalse(MeshDeleteTargets.gone(deleteStatus: 403, checkStatus: 404))
    }

    /// Same tags as Android: delete + get, the blob, every device by its
    /// `.fips` name, five minutes.
    func testOneTokenNamesEveryDevice() {
        let targets = MeshDeleteTargets.of(devices: devices, ownNpub: own, includeHomeVault: true)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(MeshDeleteTargets.authTags(sha256: blob, targets: targets, now: now), [
            ["t", "delete"], ["t", "get"], ["x", blob],
            ["server", "\(home).fips"], ["server", "\(mac).fips"], ["server", "\(phone).fips"],
            ["expiration", "1300"],
        ])
    }
}

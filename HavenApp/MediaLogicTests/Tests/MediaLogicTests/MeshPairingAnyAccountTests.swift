import XCTest
@testable import MediaLogic

/// The Apple apps link two devices that share any account (Logen,
/// 2026-11-06): the optional `a` field in the code and the hello, and the
/// session's `matchAnyAccount`. The shared fixtures (Android, web) still
/// pin the old active-only `ownerCheck`; MeshPairingTests covers that.
final class MeshPairingAnyAccountTests: XCTestCase {
    private let active = "npub1emme6lujwlzw6y2afr6teeuhgf7rt3n6yg40aagpyfuhuu06xf9q6z30yj"
    private let second = "npub1d3lkmjhu0mml5fy8tny0sqc55ggm9jsevx40pvurwlstvx9a7hpspnlmth"
    private let stranger = "npub1mfvctm9654sq6qqasdg6g27z0ms2yj9udt30w50eztsqjuv6sd3qzesed5"
    private let mesh = "npub1jc7rrss6ua9nxpqlwvcshs6rq8pdgjx6a6m63ey243nrjf7wqv3sy8aysl"
    private let secret = "MfL-vrRY_QiUhuVK2cwvQQ"

    func testCodeCarriesTheOtherAccounts() throws {
        let uri = MeshPairing.build(mesh: mesh, name: "Mac", role: .phone, owner: active, code: .secret(secret),
                                    accounts: [active, second, second, "npub1nope"])
        XCTAssertTrue(uri.contains("&a=\(second)"), uri)
        let p = try MeshPairing.parse(uri, ownMesh: nil).get()
        XCTAssertEqual(p.owner, active)
        XCTAssertEqual(p.accounts, [second], "owner is in o, repeats and non-npubs are dropped")
        // No accounts: the code is exactly what it was.
        XCTAssertFalse(MeshPairing.build(mesh: mesh, name: "Mac", role: .phone, owner: active, code: .secret(secret)).contains("a="))
    }

    func testABadAccountsFieldIsIgnoredNotRefused() throws {
        let base = MeshPairing.build(mesh: mesh, name: "Mac", role: .phone, owner: active, code: .secret(secret))
        let p = try MeshPairing.parse(base + "&a=nsec1xyz,,\(second)", ownMesh: nil).get()
        XCTAssertEqual(p.accounts, [second])
    }

    func testHelloCarriesTheAccounts() throws {
        let json = MeshPairing.helloJSON(secret: secret, name: "iPad", role: .phone, owner: active, time: 1,
                                         accounts: [active, second])
        let h = try XCTUnwrap(MeshPairing.parseHello(json))
        XCTAssertEqual(h.accounts, [second])
        XCTAssertEqual(MeshPairing.parseHello(MeshPairing.helloJSON(secret: secret, name: "iPad", role: .phone,
                                                                    owner: active, time: 1))?.accounts, [])
    }

    func testSharesAnyAccount() {
        XCTAssertTrue(MeshPairing.sharesAccount(owner: active, theirs: [], mine: [active]))
        // The Mac signed in as one account with a vault of another (Logen's case).
        XCTAssertTrue(MeshPairing.sharesAccount(owner: stranger, theirs: [second], mine: [second]))
        XCTAssertTrue(MeshPairing.sharesAccount(owner: second, theirs: [], mine: [active, second]))
        XCTAssertFalse(MeshPairing.sharesAccount(owner: stranger, theirs: [], mine: [active, second]))
        XCTAssertFalse(MeshPairing.sharesAccount(owner: "npub1nope", theirs: ["npub1nope"], mine: ["npub1nope"]))
    }

    private func session(any: Bool) -> MeshPairingSession {
        MeshPairingSession(secret: secret, createdAt: 1_793_800_000,
                           ownMeshHex: "f29276ce125c563297e8f62e302c5d9e23d98f88ad7bd04f40f467c3a371730a",
                           active: active, accounts: [active, second], matchAnyAccount: any)
    }

    private func hello(owner: String, accounts: [String] = []) -> String {
        MeshPairing.helloJSON(secret: secret, name: "Logen's iPhone", role: .phone, owner: owner,
                              time: 1_793_800_010, accounts: accounts)
    }

    private let sender = "963c31c21ae74b33041f73310bc34301c2d448daeeb7a8e48aac663927ce0323"

    func testSessionTakesAHelloThatSharesAnyAccount() {
        var s = session(any: true)
        guard case .camera = s.receiveHello(senderHex: sender, content: hello(owner: second), now: 1_793_800_012) else {
            return XCTFail("another account on this device is shared")
        }
        var t = session(any: true)
        guard case .camera = t.receiveHello(senderHex: sender, content: hello(owner: stranger, accounts: [second]),
                                            now: 1_793_800_012) else {
            return XCTFail("a shared account in a is enough")
        }
        var u = session(any: true)
        XCTAssertEqual(u.receiveHello(senderHex: sender, content: hello(owner: stranger), now: 1_793_800_012),
                       .refuse(.otherOwner))
    }

    /// Off (the shared contract, as Android): another account still asks to switch.
    func testSessionWithoutTheRuleKeepsTheContract() {
        var s = session(any: false)
        XCTAssertEqual(s.receiveHello(senderHex: sender, content: hello(owner: second), now: 1_793_800_012),
                       .refuse(.switchTo))
    }

    /// The flow uses the new rule on both sides and sends its accounts.
    func testPairDeviceFlowUsesTheRule() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HavenApp")
        let text = try String(contentsOf: app.appendingPathComponent("Views/Pairing/PairDeviceFlow.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("matchAnyAccount: true"))
        XCTAssertTrue(text.contains("MeshPairing.sharesAccount(owner: payload.owner, theirs: payload.accounts"))
        XCTAssertFalse(text.contains("MeshPairing.ownerCheck("))
        XCTAssertEqual(text.components(separatedBy: "accounts: config.allAccountNpubs)").count - 1, 3,
                       "both codes and the hello carry this device's accounts")
    }
}

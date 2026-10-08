import XCTest
@testable import MediaLogic

final class LocalTLSPolicyTests: XCTestCase {
    func testLoopbackIsTrustedAsIs() {
        for host in ["localhost", "127.0.0.1", "127.0.0.2", "::1", "[::1]", "0.0.0.0", "LOCALHOST"] {
            XCTAssertEqual(LocalTLSPolicy.kind(of: host), .loopback, host)
        }
    }

    func testPrivateAddressesAndMDNSArePinned() {
        for host in ["10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.1.20", "macbook.local"] {
            XCTAssertEqual(LocalTLSPolicy.kind(of: host), .lan, host)
        }
    }

    /// The old check matched on a name's first characters, so these got any
    /// certificate accepted.
    func testLookalikesArePublic() {
        for host in ["10.example.com", "172.example.com", "172.32.0.1", "172.15.0.1",
                     "192.168.example.com", "10.0.0", "10.0.0.256", "relay.damus.io", "local", ""] {
            XCTAssertEqual(LocalTLSPolicy.kind(of: host), .public, host)
        }
        XCTAssertEqual(LocalTLSPolicy.kind(of: nil), .public)
    }

    func testPinOnFirstUseThenRequireTheSameCertificate() {
        XCTAssertEqual(LocalTLSPolicy.decide(pinned: nil, presented: "aa"), .acceptAndPin)
        XCTAssertEqual(LocalTLSPolicy.decide(pinned: "aa", presented: "aa"), .accept)
        XCTAssertEqual(LocalTLSPolicy.decide(pinned: "aa", presented: "bb"), .reject)
    }

    // MARK: - Saved certificates

    private final class Storage {
        var pins: [String: String]? = nil
    }

    private func store(_ storage: Storage) -> LocalTLSPins {
        LocalTLSPins(load: { storage.pins ?? [:] }, save: { storage.pins = $0 })
    }

    /// The sequence that can lock a phone out of its relay, and the way back.
    func testSaveThenRefuseThenTrustNew() {
        let storage = Storage()
        let pins = store(storage)
        XCTAssertEqual(pins.check("192.168.1.20:4869", fingerprint: "aa"), .accepted)
        XCTAssertEqual(storage.pins, ["192.168.1.20:4869": "aa"])
        XCTAssertEqual(pins.check("192.168.1.20:4869", fingerprint: "aa"), .accepted)

        XCTAssertEqual(pins.check("192.168.1.20:4869", fingerprint: "bb"), .refused(firstTime: true))
        XCTAssertEqual(pins.check("192.168.1.20:4869", fingerprint: "bb"), .refused(firstTime: false))
        XCTAssertEqual(pins.refusedHosts, ["192.168.1.20:4869"])
        XCTAssertEqual(storage.pins, ["192.168.1.20:4869": "aa"], "a refusal must not overwrite the saved one")

        pins.forget("192.168.1.20:4869")
        XCTAssertTrue(pins.refusedHosts.isEmpty)
        XCTAssertEqual(pins.check("192.168.1.20:4869", fingerprint: "bb"), .accepted)
        XCTAssertEqual(storage.pins, ["192.168.1.20:4869": "bb"])
    }

    func testPinsSurviveARestart() {
        let storage = Storage()
        XCTAssertEqual(store(storage).check("macbook.local:4869", fingerprint: "aa"), .accepted)
        XCTAssertEqual(store(storage).check("macbook.local:4869", fingerprint: "bb"), .refused(firstTime: true))
    }

    /// Reset App: the relay comes back with a new certificate, which must be accepted.
    func testForgetAllClearsEveryPin() {
        let storage = Storage()
        let pins = store(storage)
        _ = pins.check("10.0.0.5:4869", fingerprint: "aa")
        _ = pins.check("10.0.0.5:4869", fingerprint: "bb")
        pins.forgetAll()
        XCTAssertNil(storage.pins)
        XCTAssertTrue(pins.refusedHosts.isEmpty)
        XCTAssertEqual(pins.check("10.0.0.5:4869", fingerprint: "bb"), .accepted)
    }
}


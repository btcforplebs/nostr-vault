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
}

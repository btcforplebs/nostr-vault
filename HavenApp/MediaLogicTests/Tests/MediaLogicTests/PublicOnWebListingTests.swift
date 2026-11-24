import XCTest
@testable import MediaLogic

/// Your Vault › Public on the web (Mac): the switch lists or unlists the
/// vault's own domain in the 10002, the 10050 and relay hints. The package
/// builds for macOS, so the DM inbox runs its macOS branch.
final class PublicOnWebListingTests: XCTestCase {
    private func config(domain: String, publicOnWeb: Bool?) -> HavenConfig {
        var c = HavenConfig()
        c.relayURL = domain
        c.publicOnWeb = publicOnWeb
        return c
    }

    /// Never touched: a domain already set keeps being listed, as before the switch.
    func testUntouchedSwitchKeepsAnExistingDomainListed() {
        let c = config(domain: "vault.example.com", publicOnWeb: nil)
        XCTAssertTrue(c.listsOwnDomain)
        XCTAssertEqual(c.ownPublicRelays.first, "wss://vault.example.com")
        XCTAssertEqual(c.ownHavenDMInboxURL, "wss://vault.example.com/inbox")
        XCTAssertEqual(c.publicRelayHint, "wss://vault.example.com")
    }

    /// Off: the domain still serves, but goes in no list or hint.
    func testOffTakesTheDomainOutOfEveryList() {
        let c = config(domain: "vault.example.com", publicOnWeb: false)
        XCTAssertFalse(c.listsOwnDomain)
        XCTAssertFalse(c.ownPublicRelays.contains("wss://vault.example.com"))
        XCTAssertEqual(c.ownHavenDMInboxURL, "")
        XCTAssertEqual(c.publicRelayHint, "")
        XCTAssertEqual(c.sanitizedRelayURL, "vault.example.com", "turning it off keeps the domain")
    }

    /// A new vault (no domain) lists nothing, switch or not: off by default.
    func testNoDomainListsNothing() {
        for value in [nil, true, false] as [Bool?] {
            let c = config(domain: "", publicOnWeb: value)
            XCTAssertFalse(c.listsOwnDomain, "\(String(describing: value))")
            XCTAssertEqual(c.ownHavenDMInboxURL, "")
            XCTAssertEqual(c.publicRelayHint, "")
        }
    }

    /// The private-network checks stay where they were: a LAN address is
    /// still never put in the DM inbox or a hint, switch on or not.
    func testLanAddressStaysOutOfInboxAndHints() {
        let c = config(domain: "192.168.1.20:3355", publicOnWeb: true)
        XCTAssertEqual(c.ownHavenDMInboxURL, "")
        XCTAssertEqual(c.publicRelayHint, "")
    }

    /// A bare IP is never listed, switch on or untouched (Tron must-fix 1 on
    /// #2512): not in 10002, the DM inbox or a hint. isPrivateNetworkHost
    /// lets a WAN address through, so this is the only stop.
    func testABareIPIsNeverListed() {
        for domain in ["203.0.113.7", "203.0.113.7:4869", "[2001:db8::1]:443", "2001:db8::1"] {
            for value in [nil, true] as [Bool?] {
                let c = config(domain: domain, publicOnWeb: value)
                XCTAssertFalse(c.listsOwnDomain, domain)
                XCTAssertFalse(c.ownPublicRelays.contains { $0.contains(domain) }, domain)
                XCTAssertEqual(c.ownHavenDMInboxURL, "", domain)
                XCTAssertEqual(c.publicRelayHint, "", domain)
            }
        }
    }

    /// A failed list edit snaps the switch back (Tron should-fix 2 on #2512):
    /// off reads off only when every list dropped the domain; on falls back
    /// to off only when no list took it.
    func testTheSwitchSnapsBackOnAFailedEdit() {
        XCTAssertFalse(HavenConfig.publicOnWebAfterEdits(on: false, done: [true, true]))
        XCTAssertTrue(HavenConfig.publicOnWebAfterEdits(on: false, done: [false, false]))
        XCTAssertTrue(HavenConfig.publicOnWebAfterEdits(on: false, done: [true, false]), "10050 still lists it")
        XCTAssertTrue(HavenConfig.publicOnWebAfterEdits(on: false, done: [false, true]), "10002 still lists it")
        XCTAssertTrue(HavenConfig.publicOnWebAfterEdits(on: true, done: [true, true]))
        XCTAssertTrue(HavenConfig.publicOnWebAfterEdits(on: true, done: [true, false]), "10002 lists it")
        XCTAssertTrue(HavenConfig.publicOnWebAfterEdits(on: true, done: [false, true]), "10050 lists it")
        XCTAssertFalse(HavenConfig.publicOnWebAfterEdits(on: true, done: [false, false]))
    }

    /// Saved and loaded: on, off and never touched each survive, and an old
    /// config without the key loads as never touched.
    func testTheSwitchRoundTripsAndOldConfigsLoadAsUntouched() throws {
        for value in [nil, true, false] as [Bool?] {
            let data = try JSONEncoder().encode(config(domain: "vault.example.com", publicOnWeb: value))
            XCTAssertEqual(try JSONDecoder().decode(HavenConfig.self, from: data).publicOnWeb, value)
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig())) as! [String: Any]
        json.removeValue(forKey: "publicOnWeb")
        let old = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.publicOnWeb)
    }
}

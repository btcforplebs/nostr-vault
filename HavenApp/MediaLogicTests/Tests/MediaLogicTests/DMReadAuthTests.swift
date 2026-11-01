import XCTest
@testable import MediaLogic

/// NIP-42 on the external DM read: a relay that closes the wrap REQ with
/// "auth-required" gets one AUTH, then the REQ again. Never a loop.
final class DMReadAuthTests: XCTestCase {
    private let req = #"["REQ","ext-nip17-a",{"kinds":[1059]}]"#

    private func reading() -> DMReadAuth {
        var auth = DMReadAuth(mayAuth: true)
        auth.sent(subId: "ext-nip17-a", req: req)
        return auth
    }

    func testChallengeThenClosedSignsThenResendsOnOK() {
        var auth = reading()
        XCTAssertEqual(auth.receive(type: "AUTH", json: ["AUTH", "c1"]), .none)
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: sign in"]), .sign(challenge: "c1"))
        XCTAssertTrue(auth.isAuthenticating)
        auth.authSent(id: "auth1")
        XCTAssertEqual(auth.receive(type: "OK", json: ["OK", "auth1", true, ""]), .resend([req]))
        XCTAssertFalse(auth.isAuthenticating)
    }

    /// The CLOSED can beat the challenge: sign once the challenge lands.
    func testClosedBeforeChallengeWaitsForIt() {
        var auth = reading()
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"]), .none)
        XCTAssertEqual(auth.receive(type: "AUTH", json: ["AUTH", "c2"]), .sign(challenge: "c2"))
    }

    /// A relay handing out a fresh challenge with every refusal must not get
    /// a second signature on the same connection (web #879).
    func testOneSignaturePerConnection() {
        var auth = reading()
        auth.sent(subId: "ext-nip04-in-b", req: "r2")
        _ = auth.receive(type: "AUTH", json: ["AUTH", "c1"])
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"]), .sign(challenge: "c1"))
        XCTAssertEqual(auth.receive(type: "AUTH", json: ["AUTH", "c2"]), .none)
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip04-in-b", "auth-required: x"]), .none)
        auth.authSent(id: "a")
        XCTAssertEqual(auth.receive(type: "OK", json: ["OK", "a", true, ""]), .resend([req, "r2"]))
    }

    func testClosedAgainAfterAuthGivesUp() {
        var auth = reading()
        _ = auth.receive(type: "AUTH", json: ["AUTH", "c1"])
        _ = auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"])
        auth.authSent(id: "a")
        _ = auth.receive(type: "OK", json: ["OK", "a", true, ""])
        guard case .giveUp = auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"]) else {
            return XCTFail("a second auth-required must give up")
        }
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"]), .none)
        XCTAssertEqual(auth.receive(type: "AUTH", json: ["AUTH", "c9"]), .none)
    }

    func testRefusedAuthGivesUpAndNeverSignsAgain() {
        var auth = reading()
        _ = auth.receive(type: "AUTH", json: ["AUTH", "c1"])
        _ = auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"])
        auth.authSent(id: "a")
        XCTAssertEqual(auth.receive(type: "OK", json: ["OK", "a", false, "restricted"]), .giveUp("AUTH refused: restricted"))
        XCTAssertEqual(auth.receive(type: "AUTH", json: ["AUTH", "c2"]), .none)
    }

    func testSignerDecliningGivesUp() {
        var auth = reading()
        _ = auth.receive(type: "AUTH", json: ["AUTH", "c1"])
        _ = auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"])
        XCTAssertEqual(auth.signFailed(), .giveUp("not signed"))
        XCTAssertEqual(auth.receive(type: "AUTH", json: ["AUTH", "c2"]), .none)
    }

    /// A relay given up on earlier this session is not asked to sign again.
    func testSkippedRelayNeverSigns() {
        var auth = DMReadAuth(mayAuth: false)
        auth.sent(subId: "ext-nip17-a", req: req)
        _ = auth.receive(type: "AUTH", json: ["AUTH", "c1"])
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "auth-required: x"]), .none)
    }

    func testOtherClosesAndStrangeFramesAreIgnored() {
        var auth = reading()
        _ = auth.receive(type: "AUTH", json: ["AUTH", "c1"])
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "ext-nip17-a", "rate-limited: slow"]), .none)
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED", "someone-else", "auth-required: x"]), .none)
        XCTAssertEqual(auth.receive(type: "CLOSED", json: ["CLOSED"]), .none)
        XCTAssertEqual(auth.receive(type: "OK", json: ["OK", "unrelated", true]), .none)
        XCTAssertEqual(auth.receive(type: "AUTH", json: ["AUTH"]), .none)
    }

    // MARK: - Fetch order

    func testDMInboxRelaysComeBeforeReadRelaysUnderTheCap() {
        let read = (1...14).map { "wss://feed\($0).example" }
        let relays = DMReadAuth.fetchRelays([["wss://inbox.example"], ["wss://relay.damus.io", "wss://nostr.wine/"], read], cap: 15)
        XCTAssertEqual(Array(relays.prefix(3)), ["wss://inbox.example", "wss://relay.damus.io", "wss://nostr.wine/"])
        XCTAssertEqual(relays.count, 15)
    }

    func testFetchRelaysDropDuplicates() {
        let relays = DMReadAuth.fetchRelays([["wss://Relay.Damus.io/"], ["wss://relay.damus.io", " "]], cap: 15)
        XCTAssertEqual(relays, ["wss://Relay.Damus.io/"])
    }
}

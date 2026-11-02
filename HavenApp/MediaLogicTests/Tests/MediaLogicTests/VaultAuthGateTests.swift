import XCTest
@testable import MediaLogic

final class VaultAuthGateTests: XCTestCase {
    private func authed() -> VaultAuthGate {
        var gate = VaultAuthGate()
        XCTAssertTrue(gate.challenge())
        gate.sentAuth(id: "a1")
        XCTAssertEqual(gate.handle(type: "OK", ["OK", "a1", true, ""]), .start)
        return gate
    }

    func testOnlyTheFirstChallengeIsSigned() {
        var gate = VaultAuthGate()
        XCTAssertTrue(gate.challenge())
        XCTAssertFalse(gate.challenge())
    }

    /// The build 54 bug: the REQ sent before the AUTH lands is refused. That
    /// refusal must not end the query; the REQ goes again on the AUTH's OK.
    func testRefusalBeforeAuthOkWaitsForTheOk() {
        var gate = VaultAuthGate()
        XCTAssertEqual(gate.handle(type: "CLOSED", ["CLOSED", "s", "auth-required: log in"]), .ignore)
        XCTAssertTrue(gate.challenge())
        gate.sentAuth(id: "a1")
        XCTAssertEqual(gate.handle(type: "CLOSED", ["CLOSED", "s", "auth-required: log in"]), .ignore)
        XCTAssertEqual(gate.handle(type: "OK", ["OK", "a1", true, ""]), .start)
    }

    func testRefusedAuthFails() {
        var gate = VaultAuthGate()
        _ = gate.challenge()
        gate.sentAuth(id: "a1")
        XCTAssertEqual(gate.handle(type: "OK", ["OK", "a1", false, "restricted: not the owner"]), .fail)
    }

    func testOneRetryAfterAuthThenFail() {
        var gate = authed()
        XCTAssertEqual(gate.handle(type: "CLOSED", ["CLOSED", "s", "auth-required: x"]), .start)
        XCTAssertEqual(gate.handle(type: "CLOSED", ["CLOSED", "s", "auth-required: x"]), .fail)
    }

    func testRefusedPublishCountsAsAuthRequired() {
        var gate = authed()
        XCTAssertEqual(gate.handle(type: "OK", ["OK", "e1", false, "auth-required: x"]), .start)
    }

    func testEverythingElsePassesThrough() {
        var gate = authed()
        XCTAssertEqual(gate.handle(type: "EVENT", ["EVENT", "s", [String: Any]()]), .pass)
        XCTAssertEqual(gate.handle(type: "EOSE", ["EOSE", "s"]), .pass)
        XCTAssertEqual(gate.handle(type: "OK", ["OK", "e1", true, ""]), .pass)
        XCTAssertEqual(gate.handle(type: "OK", ["OK", "e1", false, "blocked: no"]), .pass)
        XCTAssertEqual(gate.handle(type: "CLOSED", ["CLOSED", "s", "error: boom"]), .pass)
    }

    /// No challenge at all (a vault that doesn't ask): nothing is held back.
    func testNoChallengeNoGate() {
        var gate = VaultAuthGate()
        XCTAssertEqual(gate.handle(type: "EOSE", ["EOSE", "s"]), .pass)
        XCTAssertEqual(gate.handle(type: "OK", ["OK", "e1", true, ""]), .pass)
    }
}

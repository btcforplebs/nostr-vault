import XCTest
@testable import MediaLogic

/// Sync pick 1: exactly one device blasts each note. The vault does when it
/// answers OK true with no message within the hold; anything else and the
/// phone does. Throwaway ids only.
final class VaultHandoffDecisionTests: XCTestCase {
    private let id = String(repeating: "ab", count: 32)

    func testOKTrueWithinTheHoldMeansTheVaultSends() {
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: true, accepted: true, message: "", timedOut: false), .vaultSends)
    }

    func testDuplicateMeansThePhoneSends() {
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: true, accepted: false,
                                                   message: "duplicate: the vault already holds this note", timedOut: false), .phoneSends)
        // khatru's own duplicate answer is OK true: still not a blast.
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: true, accepted: true,
                                                   message: "duplicate: already have this event", timedOut: false), .phoneSends)
    }

    func testRefusalsMeanThePhoneSends() {
        for message in ["blocked: too old", "restricted: owner only", "error: failed to save"] {
            XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: true, accepted: false, message: message, timedOut: false),
                           .phoneSends, message)
        }
    }

    func testTimeoutMeansThePhoneSends() {
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: true, accepted: nil, message: nil, timedOut: true), .phoneSends)
        // An OK that lands after the hold is too late: the phone already sent.
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: true, accepted: true, message: "", timedOut: true), .phoneSends)
    }

    func testConnectFailureMeansThePhoneSends() {
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: false, accepted: nil, message: nil, timedOut: false), .phoneSends)
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: true, connected: false, accepted: true, message: "", timedOut: false), .phoneSends)
    }

    func testHoldIsTenSeconds() {
        XCTAssertEqual(VaultHandoffDecision.hold, 10)
    }

    // MARK: Reading the vault's answer

    func testReadsTheOKForThisNote() {
        XCTAssertEqual(VaultHandoffDecision.okAnswer(frame: #"["OK","\#(id)",true,""]"#, eventId: id),
                       .init(accepted: true, message: ""))
        XCTAssertEqual(VaultHandoffDecision.okAnswer(frame: #"["OK","\#(id)",false,"duplicate: held"]"#, eventId: id),
                       .init(accepted: false, message: "duplicate: held"))
    }

    func testIgnoresOtherFrames() {
        let other = String(repeating: "cd", count: 32)
        XCTAssertNil(VaultHandoffDecision.okAnswer(frame: #"["OK","\#(other)",true,""]"#, eventId: id), "another note's OK")
        XCTAssertNil(VaultHandoffDecision.okAnswer(frame: #"["NOTICE","hello"]"#, eventId: id))
        XCTAssertNil(VaultHandoffDecision.okAnswer(frame: "not json", eventId: id))
        XCTAssertNil(VaultHandoffDecision.okAnswer(frame: #"["OK","\#(id)"]"#, eventId: id), "no flag")
    }

    func testAnOKWithoutAMessageIsRead() {
        XCTAssertEqual(VaultHandoffDecision.okAnswer(frame: #"["OK","\#(id)",true]"#, eventId: id),
                       .init(accepted: true, message: ""))
    }

    // MARK: The vault's publish notice (an older vault never sends one)

    func testOKTrueWithoutTheNoticeMeansThePhoneSends() {
        XCTAssertEqual(VaultHandoffDecision.decide(sawPublishNotice: false, connected: true, accepted: true,
                                                   message: "", timedOut: false), .phoneSends)
    }

    func testOnlyTheExactNoticeOpensThePublishConnection() {
        XCTAssertTrue(VaultHandoffDecision.isPublishNotice(frame: #"["NOTICE","publish-for-me: on"]"#))
        XCTAssertFalse(VaultHandoffDecision.isPublishNotice(frame: #"["NOTICE","publish-for-me: off"]"#))
        XCTAssertFalse(VaultHandoffDecision.isPublishNotice(frame: #"["NOTICE","hello"]"#))
        XCTAssertFalse(VaultHandoffDecision.isPublishNotice(frame: #"["OK","\#(id)",true,""]"#), "an OK first is an older vault")
        XCTAssertFalse(VaultHandoffDecision.isPublishNotice(frame: #"["AUTH","challenge"]"#))
        XCTAssertFalse(VaultHandoffDecision.isPublishNotice(frame: "not json"))
        XCTAssertEqual(VaultHandoffDecision.publishNotice, "publish-for-me: on")
    }

    // MARK: What is handed off (Tron, PR 1970 M1)

    func testOnlyRegularKindsAreHandedOff() {
        for kind in [1, 6, 7, 1111, 1068, 9735, 40000] {
            XCTAssertTrue(VaultHandoffDecision.handsOff(kind: kind), "\(kind)")
        }
        for kind in [0, 3, 10000, 10002, 10050, 10063, 19999, 20000, 24242, 29999, 30000, 30023, 39999] {
            XCTAssertFalse(VaultHandoffDecision.handsOff(kind: kind), "\(kind)")
        }
    }

    func testTheAuthorsRelaysAreSentAtOnceAndTheFanOutWaitsForTheHold() throws {
        let own = ["wss://own.example/", "wss://SHARED.example", "ws://127.0.0.1:4869"]
        let app = ["wss://shared.example", "wss://blastr.example"]
        let plan = try XCTUnwrap(VaultHandoffDecision.handoffPlan(authorWriteRelays: own, appWriteRelays: app))
        XCTAssertEqual(plan.confirmed, ["wss://own.example", "wss://SHARED.example"], "the author's write relays, loopback dropped")
        XCTAssertEqual(plan.alsoSend, ["wss://blastr.example"], "the fan-out the vault may take")
        XCTAssertEqual(plan, PublishTargets.plan(authorWriteRelays: own, appWriteRelays: app), "what decides Posted is unchanged")
    }

    func testAfterTheHoldOnlyTheFanOutIsLeft() throws {
        let plan = PublishTargets.Plan(confirmed: ["wss://own.example"], alsoSend: ["wss://blastr.example"])
        XCTAssertEqual(VaultHandoffDecision.relaysAfterHold(.vaultSends, plan: plan), [], "the vault fans it out")
        XCTAssertEqual(VaultHandoffDecision.relaysAfterHold(.phoneSends, plan: plan), ["wss://blastr.example"],
                       "the author's relays were sent at once, not again")
    }

    func testNoHandOffWithoutTheAuthorsOwnRelays() {
        XCTAssertNil(VaultHandoffDecision.handoffPlan(authorWriteRelays: nil, appWriteRelays: ["wss://blastr.example"]))
        XCTAssertNil(VaultHandoffDecision.handoffPlan(authorWriteRelays: [], appWriteRelays: ["wss://blastr.example"]))
        XCTAssertNil(VaultHandoffDecision.handoffPlan(authorWriteRelays: [" ", "ws://localhost:4869"],
                                                      appWriteRelays: ["wss://blastr.example"]))
    }
}

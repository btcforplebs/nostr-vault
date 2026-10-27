import XCTest
@testable import MediaLogic

final class DMTrustTests: XCTestCase {
    private let owner = "0wner"
    private let friend = "f1"
    private let stranger = "aae4b6a2"

    func testTrustedCounterpartyIsInbox() {
        XCTAssertTrue(DMTrust.isInbox(counterparty: friend, youWrote: false, trusted: [friend], own: [owner]))
    }

    func testStrangerWaitsUnderRequests() {
        XCTAssertFalse(DMTrust.isInbox(counterparty: stranger, youWrote: false, trusted: [friend], own: [owner]))
    }

    /// The reported case: someone who follows you, but nobody in your web
    /// follows them. Following you puts nobody in the trust set.
    func testFollowerOnlyStrangerIsNotTrusted() {
        let trustedFromGraph: Set<String> = [owner, friend]  // what the relay's graph holds
        XCTAssertFalse(DMTrust.isInbox(counterparty: stranger, youWrote: false, trusted: trustedFromGraph, own: [owner]))
    }

    func testAnsweringMovesAStrangerToTheInbox() {
        XCTAssertTrue(DMTrust.isInbox(counterparty: stranger, youWrote: true, trusted: [], own: [owner]))
    }

    func testNoteToSelfIsInbox() {
        XCTAssertTrue(DMTrust.isInbox(counterparty: owner, youWrote: false, trusted: [], own: [owner]))
    }

    func testEmptyTrustFailsClosed() {
        XCTAssertFalse(DMTrust.isInbox(counterparty: friend, youWrote: false, trusted: [], own: [owner]))
    }

    func testHexCaseDoesNotMatter() {
        XCTAssertTrue(DMTrust.isInbox(counterparty: "ABCD", youWrote: false, trusted: ["abcd"], own: [owner]))
    }

    func testSplitKeepsOrder() {
        struct C { let id: String; let wrote: Bool }
        let all = [C(id: stranger, wrote: false), C(id: friend, wrote: false), C(id: "s2", wrote: true), C(id: "s3", wrote: false)]
        let split = DMTrust.split(all, trusted: [friend], own: [owner], counterparty: { $0.id }, youWrote: { $0.wrote })
        XCTAssertEqual(split.inbox.map(\.id), [friend, "s2"])
        XCTAssertEqual(split.requests.map(\.id), [stranger, "s3"])
    }
}

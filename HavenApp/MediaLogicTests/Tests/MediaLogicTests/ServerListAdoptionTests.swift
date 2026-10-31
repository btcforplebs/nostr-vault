import XCTest
@testable import MediaLogic

/// Media servers set in another app (kind 10063) become upload servers
/// (Android twin: `ServerListAdoptionTest.kt`).
final class ServerListAdoptionTests: XCTestCase {
    func testTheirOrderComesFirstAndOursFollow() {
        // Logen 2026-10-31: their list in their order, then this device's others.
        let result = ServerListAdoption.adopt(
            local: ["https://blossom.primal.net", "https://only-here.example"],
            updatedAt: 100,
            published: ["https://their-first.example", "https://blossom.primal.net/", "https://their-last.example"],
            publishedAt: 200,
            base: nil
        )
        XCTAssertEqual(result?.mirrors, ["https://their-first.example", "https://blossom.primal.net",
                                         "https://their-last.example", "https://only-here.example"])
        XCTAssertEqual(result?.added, ["https://their-first.example", "https://their-last.example"])
    }

    func testTheMacAddressTheAppAddsItselfIsNotCopiedIn() {
        let result = ServerListAdoption.adopt(local: [], updatedAt: nil, published: ["https://mac.example.com/", "https://a.example"],
                                              publishedAt: 5, base: nil, ownServers: ["https://mac.example.com"])
        XCTAssertEqual(result?.mirrors, ["https://a.example"])
    }

    func testServersSetInAnotherAppAreAddedAfterTheOnesHere() {
        let result = ServerListAdoption.adopt(
            local: ["https://blossom.primal.net"],
            updatedAt: 100,
            published: ["https://blossom.primal.net/", "https://blossom.nostr.build"],
            publishedAt: 200,
            base: nil
        )
        XCTAssertEqual(result?.mirrors, ["https://blossom.primal.net", "https://blossom.nostr.build"])
        XCTAssertEqual(result?.added, ["https://blossom.nostr.build"])
        XCTAssertEqual(result?.updatedAt, 200)
    }

    func testListNoNewerThanTheLastChangeHereChangesNothing() {
        XCTAssertNil(ServerListAdoption.adopt(local: [], updatedAt: 200, published: ["https://a.example"], publishedAt: 200, base: nil))
        XCTAssertNil(ServerListAdoption.adopt(local: [], updatedAt: 300, published: ["https://a.example"], publishedAt: 200, base: nil))
    }

    func testNeverSetHereAdoptsAnyList() {
        let result = ServerListAdoption.adopt(local: [], updatedAt: nil, published: ["https://a.example"], publishedAt: 5, base: nil)
        XCTAssertEqual(result?.mirrors, ["https://a.example"])
    }

    func testServerRemovedHereIsNotAddedBack() {
        let result = ServerListAdoption.adopt(
            local: ["https://keep.example"],
            updatedAt: 100,
            published: ["https://keep.example", "https://removed.example", "https://new.example"],
            publishedAt: 200,
            base: ["https://keep.example", "https://Removed.example/"]
        )
        XCTAssertEqual(result?.mirrors, ["https://keep.example", "https://new.example"])
    }

    func testOwnRelayLoopbackMeshAndNonHttpEntriesAreSkipped() {
        let result = ServerListAdoption.adopt(
            local: [],
            updatedAt: nil,
            published: [
                "https://mac.example:4869", "http://127.0.0.1:3355", "wss://relay.example",
                "fipsmesh://npub1abc/", "not a url", "https://a.example", "https://a.example",
            ],
            publishedAt: 10,
            base: nil,
            ownServers: ["https://mac.example:4869/"]
        )
        XCTAssertEqual(result?.added, ["https://a.example"])
    }

    func testNothingNewStillStampsTheListAsSeen() {
        let result = ServerListAdoption.adopt(local: ["https://a.example"], updatedAt: 1, published: ["https://a.example"], publishedAt: 9, base: nil)
        XCTAssertEqual(result?.added, [])
        XCTAssertEqual(result?.updatedAt, 9)
    }

    func testSummaryNamesTheFirstServerAndCountsTheRest() {
        XCTAssertEqual(ServerListAdoption.summary([]), "No media server set")
        XCTAssertEqual(ServerListAdoption.summary(["https://blossom.primal.net"]), "Uploads to blossom.primal.net")
        XCTAssertEqual(ServerListAdoption.summary(["https://blossom.primal.net/", "https://a.example", "https://b.example"]),
                       "Uploads to blossom.primal.net and 2 more")
    }
}

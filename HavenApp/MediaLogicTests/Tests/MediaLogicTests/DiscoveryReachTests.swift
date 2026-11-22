import XCTest
@testable import MediaLogic

/// Settings › Feeds › Discovery reach: the bar over the desktop Vault's rank,
/// who it lets in and the live count. Android twin: `DiscoveryReachTest.kt`.
final class DiscoveryReachTests: XCTestCase {
    private func pk(_ c: Character) -> String { String(repeating: c, count: 64) }
    private var me: String { pk("a") }

    /// b follows (hop 1, 100), c hop 2 at 80, d hop 2 at 50, e hop 3 at 70,
    /// f hop 5 at 46.
    private func makeCopy(viewBar: Double = 55, floor: Double = 45) throws -> TrustRankCopy {
        let rows = [("b", 100, 1), ("c", 80, 2), ("d", 50, 2), ("e", 70, 3), ("f", 46, 5)]
            .map { "[\"\(pk(Character($0.0)))\",\($0.1),\($0.2)]" }.joined(separator: ",")
        let text = "{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":5,"
            + "\"people\":[\(rows)],\"viewBar\":\(viewBar),\"floor\":\(floor)}"
        return try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
    }

    func testTheBarStartsAtTheFilesBarAndStaysBetweenItsFloorAnd100() throws {
        let copy = try makeCopy()
        XCTAssertEqual(DiscoveryReach.bar(saved: nil, copy: copy), 55)
        XCTAssertEqual(DiscoveryReach.bar(saved: 72, copy: copy), 72)
        XCTAssertEqual(DiscoveryReach.bar(saved: 30, copy: copy), 45, "nobody under the floor reached the phone")
        XCTAssertEqual(DiscoveryReach.bar(saved: 61.6, copy: copy), 62, "whole steps")
        XCTAssertEqual(DiscoveryReach.bar(saved: 250, copy: copy), 55, "a saved bar out of 0-100 reads as unset")
        XCTAssertEqual(DiscoveryReach.bar(saved: -.infinity, copy: copy), 55)
        XCTAssertEqual(DiscoveryReach.range(copy), 45...100)
        XCTAssertEqual(DiscoveryReach.bar(saved: nil, copy: try makeCopy(viewBar: 55, floor: 45.5)), 55)
        XCTAssertEqual(DiscoveryReach.range(try makeCopy(floor: 45.5)), 46...100)
    }

    func testTheStartingBarIsSavedAsUnset() throws {
        let copy = try makeCopy()
        XCTAssertNil(DiscoveryReach.saved(55, copy: copy))
        XCTAssertEqual(DiscoveryReach.saved(60, copy: copy), 60)
    }

    func testTheBarLetsInEveryoneTwoOrMoreHopsOutAtOrOverIt() throws {
        let copy = try makeCopy()
        XCTAssertEqual(DiscoveryReach.admitted(copy, bar: 55), [pk("c"), pk("e")],
                       "follows are already your web; d and f are under the bar")
        XCTAssertEqual(DiscoveryReach.admitted(copy, bar: 50), [pk("c"), pk("d"), pk("e")], "at the bar counts")
        XCTAssertEqual(DiscoveryReach.admitted(copy, bar: 45), [pk("c"), pk("d"), pk("e"), pk("f")])
        XCTAssertEqual(DiscoveryReach.admitted(copy, bar: 100), [])
    }

    func testTheCountSplitsYourCircleFromDistantConnections() throws {
        let copy = try makeCopy()
        XCTAssertEqual(DiscoveryReach.count(copy, bar: 55), .init(circle: 1, distant: 1))
        XCTAssertEqual(DiscoveryReach.count(copy, bar: 45), .init(circle: 2, distant: 2))
        XCTAssertEqual(DiscoveryReach.countText(.init(circle: 1, distant: 1)),
                       "1 person in your circle and 1 distant connection")
        XCTAssertEqual(DiscoveryReach.countText(.init(circle: 0, distant: 2)),
                       "0 people in your circle and 2 distant connections")
    }

    func testOnlyUnderratedAndDiscoveryAreWidened() {
        XCTAssertEqual(DiscoveryReach.modes, [.underrated, .discovery])
    }

    // MARK: - The gate

    private func gate(ranked: Set<String>, blocked: Set<String> = []) -> WebGate.Web {
        var web = WebGate.Web(own: [me], web: [pk("b")], blocked: blocked)
        web.ranked = ranked
        return web
    }

    func testARankedPersonIsInsideOnlyWhereTheGateCarriesTheRank() {
        let subject = WebGate.Subject(signer: pk("e"))
        XCTAssertEqual(WebGate.judge(subject, in: gate(ranked: [])), .outside)
        XCTAssertEqual(WebGate.judge(subject, in: gate(ranked: [pk("e")])), .inside)
        XCTAssertEqual(WebGate.judge(WebGate.Subject(signer: pk("E")), in: gate(ranked: [pk("e")])), .inside,
                       "the signer is lowercased; the file's keys already are")
    }

    func testBlocksStillWinOverTheRank() {
        let blocked = gate(ranked: [pk("e")], blocked: [pk("e")])
        XCTAssertEqual(WebGate.judge(WebGate.Subject(signer: pk("e")), in: blocked), .blocked)
        let shown = gate(ranked: [pk("e")], blocked: [pk("d")])
        XCTAssertEqual(WebGate.judge(WebGate.Subject(signer: pk("e"), related: [pk("d")]), in: shown), .blocked,
                       "a ranked reposter of a blocked author is still blocked")
    }
}

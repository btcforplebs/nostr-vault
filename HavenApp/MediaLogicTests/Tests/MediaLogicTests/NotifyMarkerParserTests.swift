import XCTest
@testable import MediaLogic

/// The relay's `🔔NOTIFY|` lines are the only source of local notifications on
/// both macOS and iOS. The parser hands everything after the prefix to
/// LocalNotificationService.handle, which splits off `preview=` last because a
/// preview may hold spaces and pipes.
final class NotifyMarkerParserTests: XCTestCase {
    private func markers(_ lines: [String]) -> [String] {
        var batch = RelayLogParser.BatchedStateUpdate()
        for line in lines { RelayLogParser.collectStateChanges(from: line, into: &batch) }
        return batch.notifyMarkers
    }

    func testGoLogLineYieldsTheMarkerBody() {
        XCTAssertEqual(
            markers(["2026/10/14 10:00:00 🔔NOTIFY|type=mention|kind=1|author=ab|id=cd|recipient=ef|preview=hi | there"]),
            ["type=mention|kind=1|author=ab|id=cd|recipient=ef|preview=hi | there"]
        )
    }

    func testEveryMarkerInABatchIsKept() {
        XCTAssertEqual(markers([
            "🔔NOTIFY|type=zap|kind=9735|author=a|id=1|recipient=r|preview=21 sats",
            "2026/10/14 10:00:01 event stored",
            "🔔NOTIFY|type=dm|kind=4|author=b|id=2|recipient=r|preview=",
        ]).map { $0.components(separatedBy: "|").first }, ["type=zap", "type=dm"])
    }

    func testOrdinaryLinesYieldNoMarker() {
        XCTAssertEqual(markers([
            "2026/10/14 10:00:00 📰 new note in your inbox",
            "2026/10/14 10:00:00 blasted event to 12 relays",
        ]), [])
    }
}

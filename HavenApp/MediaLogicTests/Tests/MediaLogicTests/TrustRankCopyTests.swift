import XCTest
@testable import MediaLogic

/// The phone's copy of its Haven's rank, read with the engine's own checks
/// (trustrank.CheckHandoff). Android twin: `TrustRankCopyTest.kt`.
final class TrustRankCopyTests: XCTestCase {
    private func pk(_ c: Character) -> String { String(repeating: c, count: 64) }
    private var me: String { pk("a") }

    private func file(account: String? = nil, version: Int = 2, maxHop: Int = 4, rows: String? = nil) -> String {
        let rows = rows ?? "[\"\(pk("b"))\",80.5,2],[\"\(pk("c"))\",47,4]"
        return "{\"account\":\"\(account ?? me)\",\"builtAt\":1795300000,\"version\":\(version),\"params\":{},"
            + "\"maxHop\":\(maxHop),\"people\":[\(rows)],\"viewBar\":55,\"floor\":45}"
    }

    private func parse(_ text: String) -> TrustRankCopy? { TrustRankCopy.parse(Data(text.utf8), account: me) }

    func testAGoodCopyReadsEveryField() throws {
        let copy = try XCTUnwrap(parse(file()))
        XCTAssertEqual(copy.builtAt, 1795300000)
        XCTAssertEqual(copy.maxHop, 4)
        XCTAssertEqual(copy.floor, 45)
        XCTAssertEqual(copy.viewBar, 55)
        XCTAssertEqual(copy[pk("b")], .init(score: 80.5, hop: 2))
        XCTAssertEqual(copy[pk("c").uppercased()], .init(score: 47, hop: 4))
        XCTAssertNil(copy[pk("d")])
    }

    func testAnythingThatWouldNotPassTheEnginesChecksIsRefusedWhole() {
        let cases: [(String, String)] = [
            ("another account", file(account: pk("z"))),
            ("another version", file(version: 3)),
            ("maxHop past 6", file(maxHop: 7)),
            ("a ring past maxHop", file(maxHop: 3)),
            ("ring 0", file(rows: "[\"\(pk("b"))\",50,0]")),
            ("score over 100", file(rows: "[\"\(pk("b"))\",100.5,2]")),
            ("not a pubkey", file(rows: "[\"../x\",50,2]")),
            ("a short row", file(rows: "[\"\(pk("b"))\",50]")),
            ("a score as text", file(rows: "[\"\(pk("b"))\",\"50\",2]")),
            ("a ring as a fraction", file(rows: "[\"\(pk("b"))\",50,2.5]")),
            ("version as text", file().replacingOccurrences(of: "\"version\":2", with: "\"version\":\"2\"")),
            ("maxHop as text", file().replacingOccurrences(of: "\"maxHop\":4", with: "\"maxHop\":\"4\"")),
            ("builtAt as text", file().replacingOccurrences(of: "\"builtAt\":1795300000", with: "\"builtAt\":\"1795300000\"")),
            ("not JSON", "nope"),
        ]
        for (why, text) in cases { XCTAssertNil(parse(text), why) }
    }
}

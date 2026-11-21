import XCTest
@testable import MediaLogic

/// The constellation face must match web-vault exactly: every vector in
/// web-vault/test/fixtures/CONSTELLATION_VECTORS.json (the file the web tests
/// read, not a copy), number for number.
final class ConstellationTests: XCTestCase {
    private func vectors() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web-vault/test/fixtures/CONSTELLATION_VECTORS.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["vectors"] as? [[String: Any]])
    }

    private func nums(_ any: Any?) -> [[Double]] {
        ((any as? [[Any]]) ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
    }

    func testAllFiveVectorsMatch() throws {
        let all = try vectors()
        XCTAssertEqual(all.count, 5)
        for v in all {
            let hex = try XCTUnwrap(v["hex"] as? String)
            let c = try XCTUnwrap(Constellation(hex: hex), hex)
            let bytes = try XCTUnwrap(Constellation.bytes(ofHex: hex))
            let seed = Constellation.fnv1a(bytes)
            XCTAssertEqual(String(format: "0x%08x", seed), v["seed"] as? String, hex)
            var rng = Constellation.Mulberry32(s: seed)
            for want in (v["firstDraws"] as? [Double]) ?? [] {
                XCTAssertEqual(rng.next(), want, accuracy: 1e-10, hex)
            }
            XCTAssertEqual(c.hue, v["hue"] as? Int, hex)
            XCTAssertEqual(c.stars.count, v["n"] as? Int, hex)
            XCTAssertEqual(c.stars.map { [$0.x, $0.y, $0.r] }, nums(v["stars"]), hex)
            XCTAssertEqual(c.links, v["links"] as? [[Int]], hex)
            XCTAssertEqual(c.you, v["you"] as? Int, hex)
            XCTAssertEqual(c.dust.map { [$0.x, $0.y, $0.r] }, nums(v["dust"]), hex)
            let clouds = (v["clouds"] as? [[Any]]) ?? []
            XCTAssertEqual(c.clouds.count, clouds.count, hex)
            for (got, want) in zip(c.clouds, clouds) {
                XCTAssertEqual([got.x, got.y, got.radius], [want[0], want[1], want[2]].compactMap { ($0 as? NSNumber)?.doubleValue }, hex)
                XCTAssertEqual(got.color, want[3] as? String, hex)
                XCTAssertEqual(got.alpha, (want[4] as? NSNumber)?.doubleValue, hex)
            }
            XCTAssertEqual([c.skyInner, c.skyOuter], v["sky"] as? [String], hex)
            XCTAssertEqual(c.line, v["line"] as? String, hex)
            XCTAssertEqual(c.star, v["star"] as? String, hex)
            XCTAssertEqual(c.glow, v["glow"] as? String, hex)
        }
    }

    func testNotAKeyDrawsNothing() {
        XCTAssertNil(Constellation(hex: "abc"))
        XCTAssertNil(Constellation(hex: String(repeating: "z", count: 64)))
    }
}

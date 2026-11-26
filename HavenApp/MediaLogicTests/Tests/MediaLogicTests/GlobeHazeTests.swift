import XCTest
@testable import MediaLogic

/// The zoomed-out rings' haze (Logen 2026-11-24): decoding `haze`, the
/// rings it lands in, where its dots sit, and the inner globe's sink.
/// Android twin (H4): `GlobeHazeTest.kt`.
final class GlobeHazeTests: XCTestCase {
    private func pk(_ i: Int) -> String { String(format: "%064x", i) }
    private var me: String { pk(0xa) }

    /// globe: ring 3 top 1, 2; ring 4 top 3 (via 1). haze as given.
    private func copy(haze: String?) -> TrustRankCopy? {
        let globe = "[\"\(pk(1))\",80,3,\"\(pk(9))\"],[\"\(pk(2))\",70,3,\"\(pk(9))\"],[\"\(pk(3))\",20,4,\"\(pk(1))\"]"
        let hazeField = haze.map { ",\"haze\":\($0)" } ?? ""
        let text = "{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6,"
            + "\"people\":[[\"\(pk(9))\",100,1]],\"globe\":[\(globe)],\"viewBar\":55,\"floor\":45\(hazeField)}"
        return TrustRankCopy.parse(Data(text.utf8), account: me)
    }

    private func rows(_ from: Int, _ n: Int, score: Int = 10) -> String {
        "[" + (0..<n).map { "[\"\(pk(from + $0))\",\(score)]" }.joined(separator: ",") + "]"
    }

    func testHazeDecodesBestFirstPerRing() throws {
        let c = try XCTUnwrap(copy(haze: "{\"3\":\(rows(100, 3)),\"4\":\(rows(200, 2))}"))
        XCTAssertEqual(c.haze[3], [pk(100), pk(101), pk(102)])
        XCTAssertEqual(c.haze[4], [pk(200), pk(201)])
        XCTAssertNil(c.globePerson(pk(100)), "haze rows are not globe rows")
        XCTAssertEqual(try XCTUnwrap(copy(haze: nil)).haze, [:], "an engine from before H1")
    }

    func testABadHazeCostsOnlyTheHaze() throws {
        let bad = [
            "{\"5\":\(rows(100, 1))}",                       // no hop-5 haze
            "{\"2\":\(rows(100, 1))}",
            "{\"03\":\(rows(100, 1))}",
            "{\"3\":\(rows(100, 1, score: 0))}",              // score 0
            "{\"3\":\(rows(100, 1, score: 101))}",
            "{\"3\":[[\"nope\",10]]}",
            "{\"3\":[[\"\(pk(1))\",10]]}",                    // already a globe row
            "{\"3\":\(rows(100, 1)),\"4\":\(rows(100, 1))}",  // in two rings
            "{\"3\":\(rows(100, TrustRankCopy.hazePerRing[3]! + 1))}",
            "[1,2]",
        ]
        for haze in bad {
            let c = try XCTUnwrap(copy(haze: haze), haze)
            XCTAssertEqual(c.haze, [:], haze)
            XCTAssertEqual(c.globe.count, 3, "the globe stays: \(haze)")
            XCTAssertEqual(c.people.count, 1)
        }
        XCTAssertEqual(TrustRankCopy.parseHaze(["4": [[pk(100), 10]]], maxHop: 3, globe: [:]), [:], "past maxHop")
        XCTAssertEqual(TrustRankCopy.parseHaze(["4": [[pk(100), 10]]], maxHop: 4, globe: [:]), [4: [pk(100)]])
        let full = try XCTUnwrap(copy(haze: "{\"3\":\(rows(100, TrustRankCopy.hazePerRing[3]!))}"))
        XCTAssertEqual(full.haze[3]?.count, 700, "a full ring is kept")
    }

    func testTheCapsAreTheContracts() throws {
        let contract = try String(contentsOf: MeshCopyV2Tests.fixtures
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MESH_COPY_V2_CONTRACT.md"), encoding: .utf8)
        let m = try XCTUnwrap(contract.firstMatch(of: #/at most ([0-9,]+) and ([0-9,]+) rows/#))
        XCTAssertEqual(TrustRankCopy.hazePerRing[3], Int(m.1.replacingOccurrences(of: ",", with: "")))
        XCTAssertEqual(TrustRankCopy.hazePerRing[4], Int(m.2.replacingOccurrences(of: ",", with: "")))
        XCTAssertEqual(TrustRankCopy.hazePerRing.keys.sorted(), [3, 4], "no hop-5 haze")
    }

    func testRingsCarryTheirHazeLessBlockedPeople() throws {
        let c = try XCTUnwrap(copy(haze: "{\"3\":\(rows(100, 3)),\"4\":\(rows(200, 2))}"))
        let outer = TrustMapOuter.make(copy: c, desktopPaired: true, hidden: [pk(101)])
        XCTAssertEqual(outer.rings.first { $0.hop == 3 }?.haze, [pk(100), pk(102)])
        XCTAssertEqual(outer.rings.first { $0.hop == 4 }?.haze, [pk(200), pk(201)])
        XCTAssertEqual(outer.rings.first { $0.hop == 3 }?.count, 2, "the chip counts the tappable top only")
    }

    func testRingsInsideThePickedOneNestCentredAndShrink() {
        let half = 200.0
        XCTAssertEqual(GlobeRingZoom.nest(hop: 2, level: 0), 1)
        for hop in 3...5 {
            let level = GlobeRingZoom.level(hop: hop)
            XCTAssertEqual(GlobeRingZoom.nest(hop: hop, level: level), 1, "the picked ring keeps its size")
            let picked = GlobeRingZoom.radius(hop: hop, level: level, outline: 0.5 * half)
            var outside = picked
            for inner in (2..<hop).reversed() {
                let scale = GlobeRingZoom.nest(hop: inner, level: level)
                XCTAssertLessThan(scale, 0.85, "hop \(inner) shrinks at Hop \(hop)")
                // Onion layers: each sits inside the one round it.
                let r = (inner < 3 ? GlobeRingZoom.innerOutline(level: level, outline: 0.5 * half)
                    : GlobeRingZoom.radius(hop: inner, level: level, outline: 0.5 * half)) * scale
                XCTAssertLessThan(r, outside, "hop \(inner) at Hop \(hop)")
                outside = r
            }
        }
        // It eases: no jump between picks, both ways.
        var last = GlobeRingZoom.nest(hop: 2, level: 0)
        for step in 1...300 {
            let n = GlobeRingZoom.nest(hop: 2, level: Double(step) / 100)
            XCTAssertLessThan(abs(n - last), 0.02)
            last = n
        }
    }

    func testTheGlobeTransformShrinksInPlaceAndInvertsForTaps() {
        let size = CGSize(width: 400, height: 800)
        XCTAssertTrue(GlobeRingZoom.innerTransform(level: 0, size: size).isIdentity)
        for level in [1.0, 1.5, 2.0] {
            let t = GlobeRingZoom.innerTransform(level: level, size: size)
            let mid = CGPoint(x: 200, y: 400).applying(t)
            XCTAssertEqual(mid.x, 200, accuracy: 1e-9, "stays centred")
            XCTAssertEqual(mid.y, 400, accuracy: 1e-9, "never drops")
            XCTAssertEqual(t.a, GlobeRingZoom.innerScale(level) * GlobeRingZoom.nest(hop: 2, level: level), accuracy: 1e-9)
            let back = CGPoint(x: 230, y: 410).applying(t).applying(t.inverted())
            XCTAssertEqual(back.x, 230, accuracy: 1e-9)
            XCTAssertEqual(back.y, 410, accuracy: 1e-9)
        }
    }
}

import XCTest
import simd
@testable import MediaLogic

/// A picked hop as its own sphere (Logen 2026-11-25): where its people sit,
/// and when a ring is drawn as a sphere rather than flat.
/// Android twin (after Logen's OK): `GlobeSphereFieldTest.kt`.
final class GlobeSphereFieldTests: XCTestCase {
    private func pk(_ i: Int) -> String { String(format: "%064x", i) }

    private func hex(_ i: Int) -> String {
        // Varied bytes all the way along, like a real key, so each has its own wobble.
        (0..<8).map { String(format: "%08x", UInt32(truncatingIfNeeded: (i &+ 1) &* 2_654_435_761 &+ $0 &* 40_503)) }.joined()
    }

    func testTheTopSitOnTheSkinAndTheHazeJustUnderIt() {
        let keys = (0..<2000).map(hex)
        let pole = GlobeSphereField.pole(center: pk(0xa))
        let p = GlobeSphereField.points(keys, top: 300, pole: pole)
        XCTAssertEqual(p.count, 2000)
        let lengths = p.map(simd_length)
        XCTAssertTrue(lengths[..<300].allSatisfy { abs($0 - 1) < 1e-9 },
                      "faces out on the edge, like the Vouched shell (Logen 2026-11-25)")
        let haze = lengths[300...]
        XCTAssertTrue(haze.allSatisfy { $0 >= GlobeSphereField.hazeDepth - 1e-9 && $0 <= 1 + 1e-9 },
                      "clear of the nested globe")
        XCTAssertGreaterThan(haze.max()! - haze.min()!, 0.15, "a band, not one thin limb ring")
        XCTAssertEqual(GlobeSphereField.points(keys, top: 300, pole: pole), p, "it never moves")
    }

    func testTheBestSpreadAllRound() {
        let keys = (0..<1000).map(pk)
        let p = GlobeSphereField.points(keys, top: 300, pole: GlobeSphereField.pole(center: pk(0xa)))
        // The best 40 (the faces) are not in one cap: every octant has some,
        // and their mean direction is near the middle.
        let best = p[..<40].map(simd_normalize)
        var octants = Set<Int>()
        for v in best { octants.insert((v.x > 0 ? 1 : 0) | (v.y > 0 ? 2 : 0) | (v.z > 0 ? 4 : 0)) }
        XCTAssertEqual(octants.count, 8, "faces all round")
        let mean = best.reduce(SIMD3<Double>(repeating: 0), +) / Double(best.count)
        XCTAssertLessThan(simd_length(mean), 0.15, "no cap")
        // Seen from the front, faces reach the rim, not a ring round the middle.
        let front = p[..<300].filter { $0.z > 0 }.map { GlobeSphereField.project($0) }
        let outer = front.filter { ($0.x * $0.x + $0.y * $0.y).squareRoot() > 0.7 }.count
        XCTAssertGreaterThan(Double(outer) / Double(front.count), 0.35, "front faces out to the edge")
    }

    func testFacingIsTheDirectionNotTheDepth() {
        XCTAssertEqual(GlobeSphereField.facing(SIMD3(0, 0, 0.4)), 1, accuracy: 1e-12)
        XCTAssertEqual(GlobeSphereField.facing(SIMD3(0, 0, -0.4)), 0, accuracy: 1e-12)
        XCTAssertEqual(GlobeSphereField.facing(SIMD3(0.4, 0, 0)), 0.5, accuracy: 1e-12)
    }

    func testTheOutlineLandsOnTheSphereEdge() {
        // A point on the silhouette (seen edge-on) lands on radius 1.
        let e = GlobeSphereField.eye
        let z = 1 / e, side = (1 - z * z).squareRoot()
        let q = GlobeSphereField.project(SIMD3(side, 0, z))
        XCTAssertEqual(q.x, 1, accuracy: 1e-9)
        XCTAssertEqual(GlobeSphereField.project(SIMD3(0, 0, 1)).front, 1)
        XCTAssertEqual(GlobeSphereField.project(SIMD3(0, 0, -1)).front, 0)
        XCTAssertGreaterThan(GlobeSphereField.project(SIMD3(0, 0, 1)).scale,
                             GlobeSphereField.project(SIMD3(0, 0, -1)).scale, "near side bigger")
    }

    func testARingIsASphereOncePickedAndStaysOneWhileSunk() {
        XCTAssertEqual(GlobeRingZoom.sphere(hop: 3, level: 0), 0, "your circle draws every ring flat")
        XCTAssertEqual(GlobeRingZoom.sphere(hop: 3, level: 1), 1, "Hop 3")
        XCTAssertEqual(GlobeRingZoom.sphere(hop: 4, level: 1), 0)
        XCTAssertEqual(GlobeRingZoom.sphere(hop: 3, level: 2), 1, "Hop 4: ring 3 sinks under it, still a sphere")
        XCTAssertEqual(GlobeRingZoom.sphere(hop: 4, level: 2), 1)
        XCTAssertEqual(GlobeRingZoom.sphere(hop: 3, level: 1.5), 1, "no flat flash between Hop 3 and Hop 4")
        XCTAssertEqual(GlobeRingZoom.sphere(hop: 3, level: 0.5), 0.5, accuracy: 1e-9, "grows out of the flat ring")
    }

    func testTheWindowHoldsOnlyWhatCanBeDrawnPlusWhatIsComingRound() {
        // 300 top, best first, spread front to back.
        let fronts = (0..<300).map { 1 - Double($0) / 299 }
        let w = GlobeSphereField.window(fronts: fronts, faceFrom: 0.45, comingFrom: 0.3, faces: 72, coming: 36)
        XCTAssertEqual(w.count, 72 + 36, "not every one on the front")
        XCTAssertEqual(Array(w.prefix(72)), Array(0..<72), "the best that can show a face")
        XCTAssertTrue(w.dropFirst(72).allSatisfy { fronts[$0] >= 0.3 && fronts[$0] < 0.45 }, "the rest are at the rim")
        XCTAssertEqual(Set(w).count, w.count, "no one twice")
        XCTAssertEqual(GlobeSphereField.window(fronts: [0.1, 0.2], faceFrom: 0.45, comingFrom: 0.3, faces: 72, coming: 36), [],
                       "nothing round the back")
    }
}

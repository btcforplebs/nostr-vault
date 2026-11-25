import XCTest
import simd
@testable import MediaLogic

/// A picked hop as its own sphere (Logen 2026-11-25): where its people sit,
/// and when a ring is drawn as a sphere rather than flat.
/// Android twin (after Logen's OK): `GlobeSphereFieldTest.kt`.
final class GlobeSphereFieldTests: XCTestCase {
    private func pk(_ i: Int) -> String { String(format: "%064x", i) }

    func testEveryPointIsOnTheSphereAndItNeverMoves() {
        let keys = (0..<2000).map(pk)
        let pole = GlobeSphereField.pole(center: pk(0xa))
        let p = GlobeSphereField.points(keys, pole: pole)
        XCTAssertEqual(p.count, 2000)
        for v in p { XCTAssertEqual(simd_length(v), 1, accuracy: 1e-9) }
        XCTAssertEqual(GlobeSphereField.points(keys, pole: pole), p, "it never moves")
    }

    func testTheBestSitNearestTheFrontAndCentreAtRest() {
        let me = pk(0xa)
        let keys = (0..<1000).map(pk)
        let p = GlobeSphereField.points(keys, pole: GlobeSphereField.pole(center: me))
        // At rest the camera turns the core's direction up-right of the middle.
        let rest = simd_double3x3(GlobeCamera.facing(TrustMap.direction(of: me)))
        let fronts = p.map { GlobeSphereField.project(rest * $0).front }
        let centres = p.map { v -> Double in let q = GlobeSphereField.project(rest * v); return hypot(q.x, q.y) }
        XCTAssertGreaterThan(fronts[0], 0.999, "the best is dead front")
        XCTAssertLessThan(centres[0], 0.08, "and dead centre")
        let avg = { (s: ArraySlice<Double>) in s.reduce(0, +) / Double(s.count) }
        XCTAssertGreaterThan(avg(fronts[..<300]), avg(fronts[300...]), "the top 300 face you, the haze wraps round")
        XCTAssertLessThan(fronts[999], 0.01, "the lowest is round the back")
        XCTAssertTrue(fronts[..<300].allSatisfy { $0 > 0.65 }, "every top-300 person is on the front of Hop 3's 1,000")
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

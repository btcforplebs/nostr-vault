import XCTest
import simd
@testable import MediaLogic

final class GlobeFlatTests: XCTestCase {
    /// Keys spread like real ones: every hex digit varies.
    private func key(_ n: Int) -> String {
        var x = UInt64(n) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        return (0..<4).map { _ -> String in
            x ^= x >> 33; x &*= 0xFF51_AFD7_ED55_8CCD; x ^= x >> 33
            return String(format: "%016llx", x)
        }.joined()
    }

    func testYouSitAtTheMiddleOfTheDisc() {
        XCTAssertEqual(GlobeFlat.place(.zero, yaw: 0.7), .zero)
    }

    func testEachShellSpreadsOverItsOwnZoneOutward() {
        // Not bunched on a circle: each shell fills its zone from edge to edge,
        // evenly by area, and the zones stay apart and inside the rim.
        let shells = [TrustMap.ringRadius, TrustMap.closeRadius, TrustMap.outerRadius]
        var spans: [(Double, Double)] = []
        for radius in shells {
            let zone = GlobeFlat.zone(for: radius)
            let distances = (0..<1_000).map { simd_length(GlobeFlat.place(TrustMap.direction(of: key($0)) * radius, yaw: 0)) }
            let lo = distances.min()!, hi = distances.max()!
            XCTAssertGreaterThanOrEqual(lo, zone.inner - 1e-9)
            XCTAssertLessThanOrEqual(hi, zone.outer + 1e-9)
            // Spread across nearly the whole zone, not a band in it.
            XCTAssertGreaterThan(hi - lo, (zone.outer - zone.inner) * 0.9)
            // Even by area: about half the people are past the zone's middle by area.
            let middle = ((zone.inner * zone.inner + zone.outer * zone.outer) / 2).squareRoot()
            let outside = Double(distances.filter { $0 > middle }.count) / Double(distances.count)
            XCTAssertEqual(outside, 0.5, accuracy: 0.06)
            spans.append((lo, hi))
        }
        XCTAssertLessThan(spans[0].1, spans[1].0)
        XCTAssertLessThan(spans[1].1, spans[2].0)
        XCTAssertLessThan(spans[2].1, GlobeFlat.rim)
    }

    func testSeatedFacesOnTheDiscNeverTouch() {
        // The scene seats flat faces with the margin folded into their radius.
        let size = CGSize(width: 390, height: 844), r = 9.0
        let unit = GlobeFlat.unit(for: size)
        let room = GlobeFlat.faceRoom / (1 - TrustMap.faceOverlap)
        let spots = (0..<300).map { n -> TrustMap.FaceSpot in
            let q = GlobeFlat.place(TrustMap.direction(of: key(n)) * TrustMap.ringRadius, yaw: 0) * unit
            return TrustMap.FaceSpot(key: key(n), x: q.x, y: q.y, r: r * room)
        }
        let seated = spots.filter { TrustMap.seatFaces(spots).contains($0.key) }
        XCTAssertGreaterThan(seated.count, 20)
        for (i, a) in seated.enumerated() {
            for b in seated[(i + 1)...] {
                XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), 2 * r * GlobeFlat.faceRoom - 1e-9)
            }
        }
    }

    func testAStarBetweenShellsSitsBetweenTheirZones() {
        let author = GlobeFlat.zone(for: TrustMap.authorRadius)
        let ring = GlobeFlat.zone(for: TrustMap.ringRadius), close = GlobeFlat.zone(for: TrustMap.closeRadius)
        XCTAssertGreaterThan(author.inner, ring.inner)
        XCTAssertLessThan(author.outer, close.outer)
    }

    func testTheDiscTurnsWithTheGlobesDrift() {
        // The idle drift turns the globe about its axis; the flat view turns
        // the same way by the same angle, and its distances stay put.
        let p = TrustMap.direction(of: key(3)) * TrustMap.closeRadius
        let turn = simd_double3x3(simd_quatd(angle: 0.4, axis: SIMD3(0, 1, 0)))
        let yaw = GlobeFlat.yaw(of: turn)
        XCTAssertEqual(abs(yaw), 0.4, accuracy: 1e-9)
        let a = GlobeFlat.place(p, yaw: 0), b = GlobeFlat.place(p, yaw: yaw)
        XCTAssertEqual(simd_length(a), simd_length(b), accuracy: 1e-9)
        let turned = atan2(b.y, b.x) - atan2(a.y, a.x)
        XCTAssertEqual(abs(remainder(turned, 2 * .pi)), 0.4, accuracy: 1e-9)
    }

    func testInnerRingsDrawOverOuterOnesAndNothingIsBehind() {
        let depths = [0, TrustMap.ringRadius, TrustMap.closeRadius, TrustMap.outerRadius]
            .map { GlobeFlat.depth(SIMD3(0, 0, 1) * $0) }
        XCTAssertEqual(depths, depths.sorted(by: >))
        // The globe hides a face below -0.1 depth: on the disc none is hidden.
        XCTAssertTrue(depths.allSatisfy { $0 > 0 })
    }

    func testTheDiscFitsTheScreenAndCantBePannedAway() {
        let size = CGSize(width: 390, height: 844)
        XCTAssertLessThanOrEqual(GlobeFlat.rim * GlobeFlat.unit(for: size) * 2, 390)
        let far = GlobeFlat.clamp(SIMD2(5_000, -5_000), in: size)
        XCTAssertEqual(far, SIMD2(195, -422))
    }
}

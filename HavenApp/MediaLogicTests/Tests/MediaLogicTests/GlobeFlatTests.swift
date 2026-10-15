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

    func testTheMapKeepsTheGlobesTurn() {
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

    private let phone = CGSize(width: 390, height: 844)
    private let pad = CGSize(width: 1032, height: 1376)

    func testTheMapIsManyScreensAcrossWithRoomBetweenPeople() {
        for size in [phone, pad] {
            let unit = GlobeFlat.unit(for: size)
            XCTAssertGreaterThan(2 * GlobeFlat.rim * unit, 3 * Double(size.width), "\(size)")
            // 1,030 follows spread over their zone: on average more than a
            // face (with its margin) apart at the opening zoom.
            let zone = GlobeFlat.zone(for: TrustMap.ringRadius)
            let area = Double.pi * (zone.outer * zone.outer - zone.inner * zone.inner) * unit * unit
            let k = min(1, Double(min(size.width, size.height)) / 620)
            let face = 2 * 14 * k * GlobeFlat.scale(atZoom: 1) * GlobeFlat.faceRoom
            XCTAssertGreaterThan((area / 1_030).squareRoot(), face, "\(size)")
        }
    }

    func testTheMapOpensOnYouAndScrollsToItsEdgePlusAMargin() {
        var map = GlobeFlat.Camera()
        XCTAssertEqual(map.offset, .zero)
        XCTAssertEqual(map.zoom, 1)
        for zoom in [0.3, 1.0, 2.5] {
            map.zoom = zoom
            let reach = GlobeFlat.rim * GlobeFlat.unit(for: phone) * zoom + GlobeFlat.Camera.margin
            let expected = max(0, reach - Double(phone.width) / 2)
            for direction in [SIMD2<Double>(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1), simd_normalize(SIMD2<Double>(1, 1))] {
                map.offset = .zero
                map.pan(by: direction * 100_000, in: phone)
                // The network's far edge, plus the margin, comes in to the
                // screen's nearer side, the same distance every way: the
                // corners past the round network stay out of reach.
                XCTAssertEqual(simd_length(map.offset), expected, accuracy: 1e-6, "\(zoom) \(direction)")
                XCTAssertEqual(simd_dot(simd_normalize(map.offset + SIMD2<Double>(1e-12, 0)), direction), 1, accuracy: 1e-6)
            }
        }
    }

    func testAFlickCarriesOnSlowsAndStopsAtTheEdge() {
        var map = GlobeFlat.Camera()
        map.fling(SIMD2(1_500, 0))
        var t = 0.0
        while map.moving, t < 10 { map.step(dt: 1 / 60, in: phone); t += 1 / 60 }
        XCTAssertFalse(map.moving)
        XCTAssertGreaterThan(map.offset.x, 300)
        XCTAssertLessThan(t, 3)
        // Flung hard toward a nearby edge, it stops there. Its speed is capped.
        map.pan(by: SIMD2(-map.offset.x - 900, 0), in: phone)
        map.fling(SIMD2(-50_000, 0))
        XCTAssertEqual(simd_length(map.velocity), GlobeFlat.Camera.maxSpeed, accuracy: 1e-9)
        t = 0
        while map.moving, t < 10 { map.step(dt: 1 / 60, in: phone); t += 1 / 60 }
        XCTAssertFalse(map.moving)
        XCTAssertEqual(map.offset.x, -map.limit(in: phone), accuracy: 1e-9)
    }

    func testPlainStarsTapAtTheZoomOfTheViewYouAreIn() {
        // 2D: the globe's camera stays at 1, the map pinched to 2.5x: stars tap.
        var map = GlobeFlat.Camera()
        map.pinch(by: 2.5, in: phone)
        XCTAssertGreaterThanOrEqual(GlobeFlat.tapZoom(globe: 1, map: map.zoom, flat: 1), GlobeFlat.starTapZoom)
        // 2D from a globe zoomed to 1.6, the map out at 0.3x: they don't.
        map.pinch(by: 0.01, in: phone)
        XCTAssertEqual(map.zoom, GlobeFlat.Camera.zoomRange.lowerBound)
        XCTAssertLessThan(GlobeFlat.tapZoom(globe: 1.6, map: map.zoom, flat: 1), GlobeFlat.starTapZoom)
        // 3D is the globe's zoom, as before.
        XCTAssertEqual(GlobeFlat.tapZoom(globe: 1.6, map: 0.3, flat: 0), 1.6)
    }

    func testAPinchZoomsAboutTheMiddleOfTheScreenAndHomeGoesBackToYou() {
        var map = GlobeFlat.Camera()
        var t = 0.0
        map.pan(by: SIMD2(300, -200), in: phone)
        // The map point under the middle of the screen stays there.
        let before = -map.offset / map.zoom
        map.pinch(by: 2, in: phone)
        XCTAssertEqual(map.zoom, 2)
        XCTAssertEqual(simd_length(-map.offset / map.zoom - before), 0, accuracy: 1e-9)
        map.pinch(by: 100, in: phone)
        XCTAssertEqual(map.zoom, GlobeFlat.Camera.zoomRange.upperBound)
        map.home()
        t = 0
        while map.moving, t < 10 { map.step(dt: 1 / 60, in: phone); t += 1 / 60 }
        XCTAssertFalse(map.moving)
        XCTAssertEqual(map.offset, .zero)
        XCTAssertEqual(map.zoom, 1)
    }
}

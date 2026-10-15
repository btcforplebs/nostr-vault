import XCTest
import simd
@testable import MediaLogic

final class GlobeFlatTests: XCTestCase {
    private func key(_ n: Int) -> String { String(format: "%064x", n * 0x1234567 + 1) }

    func testYouSitAtTheMiddleOfTheDisc() {
        XCTAssertEqual(GlobeFlat.place(.zero, yaw: 0.7), .zero)
    }

    func testEachShellIsItsOwnRingOutward() {
        // Every star of a shell lands inside its band, and the bands don't
        // overlap: follows, then Close, then the outer haze.
        let shells = [TrustMap.ringRadius, TrustMap.closeRadius, TrustMap.outerRadius]
        var bands: [(Double, Double)] = []
        for radius in shells {
            let distances = (0..<400).map { simd_length(GlobeFlat.place(TrustMap.direction(of: key($0)) * radius, yaw: 0)) }
            let lo = distances.min()!, hi = distances.max()!
            XCTAssertGreaterThanOrEqual(lo, radius * (1 - GlobeFlat.bandSpread) - 1e-9)
            XCTAssertLessThanOrEqual(hi, radius * (1 + GlobeFlat.bandSpread) + 1e-9)
            bands.append((lo, hi))
        }
        XCTAssertLessThan(bands[0].1, bands[1].0)
        XCTAssertLessThan(bands[1].1, bands[2].0)
        XCTAssertLessThan(bands[2].1, GlobeFlat.rim)
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

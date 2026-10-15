import XCTest
@testable import MediaLogic

final class GlobeEdgeTests: XCTestCase {
    private let depths = stride(from: -1.7, through: 1.7, by: 0.001).map { $0 }

    func testAFaceFadesOutTowardTheRimWithoutAStep() {
        // Whole in front, gone round the back where it loses its seat.
        XCTAssertEqual(GlobeEdge.face(depth: 1.0), 1)
        XCTAssertEqual(GlobeEdge.face(depth: GlobeEdge.faceGone), 0)
        // Smooth: one thousandth of depth never moves it by more than a hair,
        // and it never brightens rolling backward.
        for (a, b) in zip(depths, depths.dropFirst()) {
            let fa = GlobeEdge.face(depth: a), fb = GlobeEdge.face(depth: b)
            XCTAssertLessThan(abs(fb - fa), 0.01)
            XCTAssertGreaterThanOrEqual(fb, fa)
        }
        // It shrinks onto its ember, not to nothing.
        XCTAssertEqual(GlobeEdge.faceRadius(10, shown: 0), 6)
        XCTAssertEqual(GlobeEdge.faceRadius(10, shown: 1), 10)
    }

    func testALiveStarDimsRoundTheBackWithoutAStep() {
        // The old rule switched from full to a third at depth -0.2.
        XCTAssertEqual(GlobeEdge.arc(depth: 1), 1)
        XCTAssertEqual(GlobeEdge.arc(depth: -1), 0.35, accuracy: 1e-12)
        for (a, b) in zip(depths, depths.dropFirst()) {
            XCTAssertLessThan(abs(GlobeEdge.arc(depth: b) - GlobeEdge.arc(depth: a)), 0.01)
        }
    }

    func testASeatFadesInAQuarterSecondAndReduceMotionCuts() {
        var fade = 0.0, t = 0.0
        while fade < 1, t < 2 { fade = GlobeEdge.seat(fade, seated: true, dt: 1 / 60, reduceMotion: false); t += 1 / 60 }
        XCTAssertEqual(fade, 1)
        XCTAssertGreaterThan(t, 0.2)
        XCTAssertLessThan(t, 0.5)
        // The first frame only starts it: no pop.
        XCTAssertLessThan(GlobeEdge.seat(0, seated: true, dt: 1 / 60, reduceMotion: false), 0.25)
        XCTAssertEqual(GlobeEdge.seat(0, seated: true, dt: 1 / 60, reduceMotion: true), 1)
        XCTAssertEqual(GlobeEdge.seat(1, seated: false, dt: 1 / 60, reduceMotion: true), 0)
    }
}

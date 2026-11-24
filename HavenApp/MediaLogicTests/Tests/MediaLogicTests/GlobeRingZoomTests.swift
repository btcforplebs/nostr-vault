import XCTest
@testable import MediaLogic

/// The Hop layers' zoom out to an outer ring. Android twin: `GlobeRingZoomTest.kt`.
final class GlobeRingZoomTests: XCTestCase {
    private let outline = 150.0, half = 200.0

    func testHopsMapToLevelsAndYourCircleToZero() {
        XCTAssertEqual(GlobeRingZoom.level(hop: nil), 0)
        XCTAssertEqual(GlobeRingZoom.level(hop: 3), 1)
        XCTAssertEqual(GlobeRingZoom.level(hop: 4), 2)
        XCTAssertEqual(GlobeRingZoom.level(hop: 5), 3)
        XCTAssertEqual(GlobeRingZoom.level(hop: 9), 3)
    }

    func testLevelZeroIsTheGlobeAsItWas() {
        XCTAssertEqual(GlobeRingZoom.innerScale(0), 1)
        XCTAssertEqual(GlobeRingZoom.innerAlpha(0), 1)
        XCTAssertEqual(GlobeRingZoom.radius(hop: 3, level: 0, outline: outline, half: half), outline * 1.72, accuracy: 1e-9)
        XCTAssertEqual(GlobeRingZoom.radius(hop: 5, level: 0, outline: outline, half: half),
                       outline * (1.72 + 2 * 0.26), accuracy: 1e-9)
        for hop in 3...5 {
            XCTAssertEqual(GlobeRingZoom.visibility(hop: hop, level: 0), 1)
            XCTAssertEqual(GlobeRingZoom.emphasis(hop: hop, level: 0), 0)
        }
    }

    func testThePickedRingFillsTheFrameAndTheGlobeShrinksAndFades() {
        for hop in 3...5 {
            let level = GlobeRingZoom.level(hop: hop)
            XCTAssertEqual(GlobeRingZoom.radius(hop: hop, level: level, outline: outline, half: half),
                           GlobeRingZoom.fit * half, accuracy: 1e-9)
            XCTAssertEqual(GlobeRingZoom.emphasis(hop: hop, level: level), 1)
            XCTAssertEqual(GlobeRingZoom.visibility(hop: hop, level: level), 1)
            XCTAssertLessThan(GlobeRingZoom.innerScale(level), 0.5)
            XCTAssertLessThan(GlobeRingZoom.innerAlpha(level), 1)
            XCTAssertGreaterThan(GlobeRingZoom.innerAlpha(level), 0, "the globe fades, never goes")
        }
        // Further out, the globe is smaller still.
        XCTAssertGreaterThan(GlobeRingZoom.innerScale(1), GlobeRingZoom.innerScale(3))
    }

    func testRingsInsideThePickedOneCloseInAndOnesPastItGo() {
        let r = { GlobeRingZoom.radius(hop: $0, level: 3, outline: self.outline, half: self.half) }
        let inner = GlobeRingZoom.innerOutline(level: 3, outline: outline)
        XCTAssertLessThan(inner, r(3))
        XCTAssertLessThan(r(3), r(4))
        XCTAssertLessThan(r(4), r(5))
        XCTAssertEqual(r(4) - r(3), r(5) - r(4), accuracy: 1e-9, "evenly spaced")
        XCTAssertEqual(GlobeRingZoom.visibility(hop: 3, level: 3), GlobeRingZoom.insideAlpha)
        XCTAssertEqual(GlobeRingZoom.visibility(hop: 5, level: 1), 0)
        XCTAssertEqual(GlobeRingZoom.emphasis(hop: 3, level: 3), 0)
    }

    func testItEasesSmoothlyBetweenLevels() {
        // Every value between two picks is drawn, both ways: no jump at a whole level.
        for hop in 3...5 {
            var last = GlobeRingZoom.radius(hop: hop, level: 0, outline: outline, half: half)
            for step in 1...300 {
                let level = Double(step) / 100
                let now = GlobeRingZoom.radius(hop: hop, level: level, outline: outline, half: half)
                XCTAssertLessThan(abs(now - last), 6, "hop \(hop) jumped at \(level)")
                last = now
            }
        }
        XCTAssertEqual(GlobeRingZoom.innerScale(0.5), (1 + GlobeRingZoom.innerScales[1]) / 2, accuracy: 1e-9)
        XCTAssertEqual(GlobeRingZoom.innerScale(.nan), 1)
        XCTAssertEqual(GlobeRingZoom.innerScale(7), GlobeRingZoom.innerScales[3])
    }
}

import XCTest
@testable import MediaLogic

/// A device added while a look runs is looked at once that look ends, not
/// five minutes later.
final class MyDevicesCheckGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAskedDuringALookWaitsThenLooksAtTheNewDevice() {
        var gate = MyDevicesCheckGate()
        XCTAssertEqual(gate.begin(asked: ["a"], force: false, now: t0), .look)
        // A device is added while the look runs.
        XCTAssertEqual(gate.begin(asked: ["a", "b"], force: false, now: t0 + 1), .wait)
        gate.finish(asked: ["a"], now: t0 + 3)
        XCTAssertEqual(gate.begin(asked: ["a", "b"], force: false, now: t0 + 3), .look)
    }

    func testSameDevicesRightAfterALookAreSkipped() {
        var gate = MyDevicesCheckGate()
        _ = gate.begin(asked: ["a"], force: false, now: t0)
        gate.finish(asked: ["a"], now: t0 + 3)
        XCTAssertEqual(gate.begin(asked: ["a"], force: false, now: t0 + 10), .skip)
        XCTAssertEqual(gate.begin(asked: ["a"], force: true, now: t0 + 10), .look)
    }

    func testSameDevicesAfterThePauseLookAgain() {
        var gate = MyDevicesCheckGate()
        _ = gate.begin(asked: ["a"], force: false, now: t0)
        gate.finish(asked: ["a"], now: t0)
        XCTAssertEqual(gate.begin(asked: ["a"], force: false, now: t0 + MyDevicesCheckGate.sameSetPause + 1), .look)
    }
}

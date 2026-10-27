import XCTest
@testable import MediaLogic

/// The Go relay's memory limit on a phone scales with its RAM. A flat
/// 256 MiB is a limit a populated vault reaches, and the collector then runs
/// back to back (iPhone 18 Pro, 2026-10-21: thermal state Serious).
final class GoMemLimitTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testAQuarterOfTheRAM() {
        XCTAssertEqual(RelayConfiguration.phoneGoMemLimitMB(physicalMemory: 4 * gib), 1024)  // iPhone 12 mini
        XCTAssertEqual(RelayConfiguration.phoneGoMemLimitMB(physicalMemory: 6 * gib), 1536)
        XCTAssertEqual(RelayConfiguration.phoneGoMemLimitMB(physicalMemory: 8 * gib), 2048)
    }

    /// Never below the old 256 MiB, never above 3 GiB on a 12 GiB+ phone.
    func testClampedBothWays() {
        XCTAssertEqual(RelayConfiguration.phoneGoMemLimitMB(physicalMemory: 512 << 20), 256)
        XCTAssertEqual(RelayConfiguration.phoneGoMemLimitMB(physicalMemory: 0), 256)
        XCTAssertEqual(RelayConfiguration.phoneGoMemLimitMB(physicalMemory: 12 * gib), 3072)  // iPhone 18 Pro
        XCTAssertEqual(RelayConfiguration.phoneGoMemLimitMB(physicalMemory: 64 * gib), 3072)
    }
}

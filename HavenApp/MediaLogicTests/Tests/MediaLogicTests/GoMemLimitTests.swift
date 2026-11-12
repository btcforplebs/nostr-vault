import XCTest
@testable import MediaLogic

/// The Go relay's memory limit on a phone scales with its RAM. A flat
/// 256 MiB is a limit a populated vault reaches, and the collector then runs
/// back to back (iPhone 18 Pro, 2026-10-21: thermal state Serious).
final class GoMemLimitTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testAQuarterOfTheRAM() {
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 4 * gib), 1024)  // iPhone 12 mini
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 6 * gib), 1536)
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 8 * gib), 2048)
    }

    /// Never below the old 256 MiB, never above 3 GiB on a 12 GiB+ phone.
    func testClampedBothWays() {
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 512 << 20), 256)
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 0), 256)
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 12 * gib), 3072)  // iPhone 18 Pro
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 64 * gib), 3072)
    }
}

/// The Mac relay got Go's flat 1 GiB (haven-go config.go), not the RAM-scaled
/// limit: on Logen's 8 GB Mac (.99, 2026-11-11) 3.2.1 ran at 450% CPU with
/// the collector on every core. The app hands every platform the same limit.
final class GoMemLimitEnvTests: XCTestCase {
    func testEveryPlatformGetsTheScaledLimit() {
        let env = RelayConfiguration.generateEnvDictionary(
            config: HavenConfig(),
            relayDataDir: FileManager.default.temporaryDirectory)
        let expected = RelayConfiguration.goMemLimitMB(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(env["GO_MEM_LIMIT_MB"], String(expected))
    }

    func testAnEightGigabyteMacGetsTwoGigabytes() {
        XCTAssertEqual(RelayConfiguration.goMemLimitMB(physicalMemory: 8 << 30), 2048)
    }
}

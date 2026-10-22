import XCTest
@testable import MediaLogic

/// Who Can Reach You only offers settings the relay actually uses.
final class RelayAccessLimitsTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// First capture group of every match.
    private func captures(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// The highest Web of Trust level haven-go runs, from its own error text.
    private func relayMaxWotLevel() throws -> Int {
        let wot = try source("haven-go/pkg/wot/simple_in_memory.go")
        let match = try XCTUnwrap(captures("must be between 0 and (\\d+)", in: wot).first)
        return try XCTUnwrap(Int(match[0]))
    }

    func testFollowDistanceStopsWhereTheRelayStops() throws {
        XCTAssertEqual(RelayAccessLimits.followDistance.upperBound, try relayMaxWotLevel())
        XCTAssertEqual(RelayAccessLimits.followDistance.lowerBound, 1)
    }

    func testOlderSavedDistanceShowsAsWhatTheRelayUses() {
        XCTAssertEqual(RelayAccessLimits.clampedFollowDistance(5), 3)
        XCTAssertEqual(RelayAccessLimits.clampedFollowDistance(4), 3)
        XCTAssertEqual(RelayAccessLimits.clampedFollowDistance(2), 2)
        XCTAssertEqual(RelayAccessLimits.clampedFollowDistance(0), 1)
    }

    /// Every config value the screen edits must reach an environment
    /// variable that haven-go reads. The old Rate Limits rows failed this:
    /// OUTBOX_MAX_EVENTS_PER_MINUTE was sent and never read.
    func testEverySettingOnTheScreenIsReadByTheRelay() throws {
        let view = try source("HavenApp/HavenApp/Views/Settings/RelayAccessSettingsView.swift")
        let env = try source("HavenApp/HavenApp/Services/RelayConfiguration.swift")
        let goDir = repo.appendingPathComponent("haven-go")
        let goFiles = try FileManager.default.contentsOfDirectory(atPath: goDir.path)
            .filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
        let go = try goFiles.map { try String(contentsOf: goDir.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        let fields = Set(try captures("\\$configService\\.config\\.(\\w+)", in: view).map { $0[0] })
        XCTAssertFalse(fields.isEmpty, "no settings found on the screen; the check can't fail")
        for field in fields {
            let keys = try captures("\"([A-Z_]+)\":[^\\n]*config\\.(\\w+)\\b", in: env)
                .filter { $0[1] == field }.map { $0[0] }
            XCTAssertFalse(keys.isEmpty, "\(field) is not passed to the relay")
            let read = try keys.filter { !(try captures("getEnv\\w*\\(\"\($0)\"", in: go)).isEmpty }
            XCTAssertFalse(read.isEmpty,
                           "\(field) is sent as \(keys) but haven-go never reads it")
        }
    }
}

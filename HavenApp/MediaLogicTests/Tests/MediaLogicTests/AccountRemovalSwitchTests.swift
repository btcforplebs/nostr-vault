import XCTest

/// Removing the active account must leave it through
/// `ConfigService.switchActiveAccount(to: nil)`, not by clearing
/// `activeAccountNpub` directly. Only the switch posts
/// `BlockedAccountsUpdated` and resets the signing mode. The switch has to
/// come after `removeBunkerConfig`: that call already detaches the active
/// signer, and its session drop must land before the owner's connect, which
/// can share the same signer session key.
/// The settings view pulls in SwiftUI and the whole app and can't be built
/// here, so this reads its source.
final class AccountRemovalSwitchTests: XCTestCase {
    private func settingsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Views/Settings/AccountsSettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func offsets(of needle: String, in source: String) -> [Int] {
        var result: [Int] = []
        var searchStart = source.startIndex
        while let r = source.range(of: needle, range: searchStart..<source.endIndex) {
            result.append(source.distance(from: source.startIndex, to: r.lowerBound))
            searchStart = r.upperBound
        }
        return result
    }

    func testRemovalNeverClearsTheActiveAccountDirectly() throws {
        let source = try settingsSource()
        XCTAssertEqual(offsets(of: "activeAccountNpub = \"\"", in: source), [])
    }

    /// Both removal paths (swipe-delete and Remove Account) switch away from
    /// the account only after its bunker config is gone.
    func testEachRemovalSwitchesAwayAfterDroppingTheSigner() throws {
        let source = try settingsSource()
        let switches = offsets(of: "switchActiveAccount(to: nil)", in: source)
        let removals = offsets(of: "removeBunkerConfig(forNpub:", in: source)
        XCTAssertEqual(removals.count, 2, "expected the swipe-delete and Remove Account paths")
        XCTAssertEqual(switches.count, removals.count)
        for (i, removal) in removals.enumerated() where i < switches.count {
            XCTAssertGreaterThan(switches[i], removal, "path \(i) switches before dropping the signer")
            if i + 1 < removals.count { XCTAssertLessThan(switches[i], removals[i + 1]) }
        }
    }
}

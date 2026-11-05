import XCTest

/// Removing the active account must leave it through
/// `ConfigService.switchActiveAccount(to: nil)`, not by clearing
/// `activeAccountNpub` directly. Only the switch posts
/// `BlockedAccountsUpdated` and resets the signing mode. The switch has to
/// come after `removeBunkerConfig`: that call already detaches the active
/// signer, and its session drop must land before the owner's connect, which
/// can share the same signer session key.
/// Both remove paths in the settings view call `ConfigService.removeAccount`.
/// Neither file can be built here (SwiftUI, the whole app), so this reads
/// their source.
final class AccountRemovalSwitchTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func settingsSource() throws -> String { try source("Views/Settings/AccountsSettingsView.swift") }
    private func removeSource() throws -> String { try source("Services/ConfigService+RemoveAccount.swift") }

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
        XCTAssertEqual(offsets(of: "activeAccountNpub = \"\"", in: try settingsSource()), [])
        XCTAssertEqual(offsets(of: "activeAccountNpub = \"\"", in: try removeSource()), [])
    }

    /// Swipe-delete and Remove Account both go through the one removal, so
    /// neither can leave the account's blocks or settings behind.
    func testBothRemovePathsUseTheOneRemoval() throws {
        let settings = try settingsSource()
        XCTAssertEqual(offsets(of: "configService.removeAccount(npub:", in: settings).count, 2)
        XCTAssertEqual(offsets(of: "removeBunkerConfig(forNpub:", in: settings), [])
        XCTAssertEqual(offsets(of: "removeCredential(forNpub:", in: settings), [])
    }

    /// The removal switches away from the account only after its bunker
    /// config is gone, drops every per-account entry, and tells the relay.
    func testTheRemovalSwitchesAwayAfterDroppingTheSigner() throws {
        let source = try removeSource()
        let removal = try XCTUnwrap(offsets(of: "removeBunkerConfig(forNpub:", in: source).first)
        let switchAway = try XCTUnwrap(offsets(of: "switchActiveAccount(to: nil)", in: source).first)
        XCTAssertGreaterThan(switchAway, removal)
        let entries = try XCTUnwrap(offsets(of: "removeAccountEntries(npub:", in: source).first)
        let sync = try XCTUnwrap(offsets(of: "syncBlacklistToRelay()", in: source).first)
        XCTAssertGreaterThan(sync, entries)
    }
}

import XCTest

/// Each account has its own block list, so switching accounts must tell the
/// screens (feed, search, DMs, quotes, polls) to re-read it at once.
/// ConfigService pulls in the whole app and can't be built here, so this
/// reads its source: `switchActiveAccount` posts `BlockedAccountsUpdated`
/// after the new account is active, never before.
final class AccountSwitchBlockListTests: XCTestCase {
    private func switchActiveAccountBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Services/ConfigService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func switchActiveAccount(to npub: String?)"))
        // The body ends at the method's closing brace, the first line that
        // is just `}` at member indent; blockProfile below posts too.
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n")).lowerBound
        return String(rest[..<end])
    }

    func testSwitchPostsBlockedAccountsUpdated() throws {
        let body = try switchActiveAccountBody()
        XCTAssertTrue(body.contains("NSNotification.Name(\"BlockedAccountsUpdated\")"))
    }

    func testSwitchPostsAfterTheNewAccountIsActive() throws {
        let body = try switchActiveAccountBody()
        let post = try XCTUnwrap(body.range(of: "BlockedAccountsUpdated"))
        let activate = try XCTUnwrap(body.range(of: "refreshActiveAccountHex()"))
        XCTAssertLessThan(activate.lowerBound, post.lowerBound)
    }
}

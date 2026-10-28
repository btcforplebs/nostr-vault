import XCTest
@testable import MediaLogic

/// Media Servers › Suggested hides a server once the user has it, however
/// they typed it, and never offers one the app would skip.
final class SuggestedMediaServersTests: XCTestCase {

    func testEmptyListShowsEverySuggestion() {
        XCTAssertEqual(SuggestedMediaServers.notYetAdded([]), SuggestedMediaServers.all)
    }

    func testAddedServerIsHiddenEvenWithSlashOrCase() {
        let left = SuggestedMediaServers.notYetAdded(["https://Blossom.Primal.net/"])
        XCTAssertFalse(left.map(\.host).contains("blossom.primal.net"))
        XCTAssertEqual(left.count, SuggestedMediaServers.all.count - 1)
    }

    /// The app uploads a typed nostr.build address to blossom.nostr.build.
    func testTypedNostrBuildHidesBlossomNostrBuild() {
        let left = SuggestedMediaServers.notYetAdded(["https://nostr.build"])
        XCTAssertFalse(left.map(\.host).contains("blossom.nostr.build"))
    }

    func testOtherServersDoNotHideSuggestions() {
        let left = SuggestedMediaServers.notYetAdded(["https://cdn.example.com", "https://nostr.band"])
        XCTAssertEqual(left, SuggestedMediaServers.all)
    }

    func testEverySuggestionIsAnHttpsServerTheAppUploadsTo() {
        XCTAssertFalse(SuggestedMediaServers.all.isEmpty)
        for server in SuggestedMediaServers.all {
            XCTAssertTrue(server.url.hasPrefix("https://"), server.url)
            XCTAssertFalse(server.url.hasSuffix("/"), server.url)
            XCTAssertEqual(HavenConfig.blossomUploadServer(server.url), server.url)
            XCTAssertFalse(HavenConfig.defunctMirrorHosts.contains(server.host), server.url)
            XCTAssertFalse(server.note.isEmpty, server.url)
        }
        XCTAssertEqual(Set(SuggestedMediaServers.all.map(\.host)).count, SuggestedMediaServers.all.count)
    }
}

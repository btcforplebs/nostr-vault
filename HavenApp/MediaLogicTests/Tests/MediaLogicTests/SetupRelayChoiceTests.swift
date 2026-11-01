import XCTest
@testable import MediaLogic

/// New-account setup: we recommend, the person picks (Logen 2026-11-01).
final class SetupRelayChoiceTests: XCTestCase {
    private let recommended = HavenConfig.starterRelays

    func testStartsEmptyWithEveryRecommendedAsASuggestion() {
        let choice = SetupRelayChoice(recommended: recommended)
        XCTAssertEqual(choice.chosen, [])
        XCTAssertEqual(choice.suggestions, recommended)
        XCTAssertFalse(choice.hasAllRecommended)
    }

    func testUseRecommendedKeepsOwnPicksFirstAndAddsNoDuplicates() {
        var choice = SetupRelayChoice(recommended: recommended)
        XCTAssertTrue(choice.add("my.relay.example"))
        XCTAssertTrue(choice.add("wss://relay.damus.io/"))
        choice.useRecommended()
        XCTAssertEqual(choice.chosen.first, "wss://my.relay.example")
        XCTAssertEqual(choice.chosen.count, 1 + recommended.count)
        XCTAssertTrue(choice.hasAllRecommended)
        XCTAssertEqual(choice.suggestions, [])
    }

    func testRemoveTurnsARecommendedRelayBackIntoASuggestion() {
        var choice = SetupRelayChoice(recommended: recommended)
        choice.useRecommended()
        choice.remove("WSS://relay.damus.io/")
        XCTAssertFalse(choice.contains("wss://relay.damus.io"))
        XCTAssertEqual(choice.suggestions, ["wss://relay.damus.io"])
    }

    func testTypedAddressesAreCleanedOrRefused() {
        XCTAssertEqual(SetupRelayChoice.cleaned("  nos.lol/ "), "wss://nos.lol")
        XCTAssertEqual(SetupRelayChoice.cleaned("wss://relay.example.com/inbox"), "wss://relay.example.com/inbox")
        for bad in ["", "   ", "ws://relay.example.com", "https://relay.example.com", "wss://localhost",
                    "wss://127.0.0.1", "wss://192.168.1.4", "notarelay", "wss://"] {
            XCTAssertNil(SetupRelayChoice.cleaned(bad), bad)
        }
        var choice = SetupRelayChoice(recommended: [])
        XCTAssertFalse(choice.add("ws://relay.example.com"))
        XCTAssertTrue(choice.add("nos.lol"))
        XCTAssertFalse(choice.add("wss://nos.lol/"), "already picked")
        XCTAssertEqual(choice.chosen, ["wss://nos.lol"])
    }

    func testPicksSurviveGoingBack() {
        let choice = SetupRelayChoice(recommended: recommended, picked: ["wss://nos.lol", "wss://relay.primal.net"])
        XCTAssertEqual(choice.chosen, ["wss://nos.lol", "wss://relay.primal.net"])
        XCTAssertFalse(choice.suggestions.contains("wss://relay.primal.net"))
    }

    /// What Confirm hands to publishNewAccount becomes the 10002 tags as is.
    func testPickedListIsWhatIsPublished() {
        var choice = SetupRelayChoice(recommended: recommended)
        choice.add("nos.lol")
        XCTAssertEqual(RelayConfiguration.newAccountRelayListTags(broadcastRelays: choice.chosen), [["r", "wss://nos.lol"]])
    }
}

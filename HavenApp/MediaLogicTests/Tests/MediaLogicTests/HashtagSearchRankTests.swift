import XCTest
@testable import MediaLogic

/// Hashtag order in Search and the Vault (search plan §1c, A5).
final class HashtagSearchRankTests: XCTestCase {
    func testTypedTagThenMostUsedThenAToZ() {
        let counts = ["bitcoiners": 1, "bitcoinart": 5, "bitcoin": 2, "bitcoinbeach": 5]
        XCTAssertEqual(HashtagSearchRank.order(counts, query: "bitcoin"),
                       ["bitcoin", "bitcoinart", "bitcoinbeach", "bitcoiners"])
    }

    func testHashAndCaseInTheQueryDoNotMatter() {
        let counts = ["nostr": 1, "nostrich": 9]
        XCTAssertEqual(HashtagSearchRank.order(counts, query: "#Nostr"), ["nostr", "nostrich"])
    }

    /// A word of a longer query is exact too, and so are the words run together.
    func testAnyWordOrTheWordsJoinedAreExact() {
        let counts = ["zapathon": 1, "zap": 1, "zaps": 4]
        XCTAssertEqual(HashtagSearchRank.order(counts, query: "nostr zap"), ["zap", "zaps", "zapathon"])
        let joined = ["plebchainradio": 7, "plebchain": 1]
        XCTAssertEqual(HashtagSearchRank.order(joined, query: "pleb chain"), ["plebchain", "plebchainradio"])
    }

    func testCountsATagOncePerItem() {
        let counts = HashtagSearchRank.counts([["a", "a", "b"], ["a"]]) { $0 }
        XCTAssertEqual(counts, ["a": 2, "b": 1])
    }

    func testVaultHashtagsUseTheOrder() {
        let tags = VaultSearchLogic.hashtags(
            contents: [("#bitcoiners #bitcoiners", []), ("#bitcoiners", []), ("#bitcoin", []),
                       ("#BitcoinArt", [["t", "bitcoinart"]])],
            query: "bitcoin")
        XCTAssertEqual(tags, ["bitcoin", "bitcoiners", "bitcoinart"])
    }
}

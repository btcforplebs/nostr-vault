import XCTest
@testable import MediaLogic

/// Payload shapes captured from wavlake.com/api/v1/content on 2026-10-02.
final class WavlakeTests: XCTestCase {
    private let rankings = #"""
    [{"id":"ba8926a3","title":"Not In Yer Wallet","albumArtUrl":"https://d12wklypp119aj.cloudfront.net/image/c6b5.jpg","artistId":"9a55","albumId":"c6b5","albumTitle":"Sound Money","mediaUrl":"https://op3.dev/e,pg=6a99/https://d12wklypp119aj.cloudfront.net/track/ba89.mp3","artist":"Rare Scrilla","url":"https://wavlake.com/track/ba8926a3","msatTotal":"5000000","duration":149},
     {"id":"nomedia","title":"Broken","artist":"X"},
     {"id":"badscheme","title":"Odd","artist":"X","mediaUrl":"ftp://example.com/a.mp3"}]
    """#

    func testRankingsKeepOnlyPlayableTracks() {
        let tracks = WavlakeAPI.tracks(fromRankings: Data(rankings.utf8))
        XCTAssertEqual(tracks.map(\.id), ["ba8926a3"])
        let t = tracks[0]
        XCTAssertEqual(t.title, "Not In Yer Wallet")
        XCTAssertEqual(t.artist, "Rare Scrilla")
        XCTAssertEqual(t.duration, 149)
        XCTAssertEqual(t.sats, 5000)
        XCTAssertEqual(t.audioURL?.pathExtension, "mp3")
        XCTAssertEqual(t.pageURL?.absoluteString, "https://wavlake.com/track/ba8926a3")
    }

    func testSearchSplitsTracksAlbumsArtists() {
        let json = #"""
        [{"id":"a1","name":"Bitcoin Block Jams","type":"artist","artistArtUrl":"https://x/a.jpg"},
         {"id":"al1","name":"Paper Bitcoin","type":"album","albumArtUrl":"https://x/b.jpg"},
         {"id":"t1","name":"Bitcoin Beach","type":"track","artist":"Someone","mediaUrl":"https://x/t1.mp3"},
         {"id":"t2","name":"No audio","type":"track"},
         {"id":"p1","name":"A podcast","type":"podcast"}]
        """#
        let results = WavlakeAPI.results(fromSearch: Data(json.utf8))
        XCTAssertEqual(results.map(\.id), ["artist:a1", "album:al1", "track:t1"])
        if case .track(let t) = results[2] { XCTAssertEqual(t.title, "Bitcoin Beach") } else { XCTFail() }
    }

    func testAlbumTracksBorrowTheAlbumArtist() {
        let json = #"""
        {"id":"al","title":"Sound Money","artist":"Rare Scrilla","tracks":[
          {"id":"t1","title":"21 Million","mediaUrl":"https://x/1.mp3","duration":200.0},
          {"id":"t2","title":"Own Name","artist":"Guest","mediaUrl":"https://x/2.mp3"}]}
        """#
        let tracks = WavlakeAPI.tracks(fromAlbum: Data(json.utf8))
        XCTAssertEqual(tracks.map(\.artist), ["Rare Scrilla", "Guest"])
        XCTAssertEqual(tracks.first?.duration, 200)
    }

    func testArtistAlbumIds() {
        let json = #"{"id":"a","name":"R","albums":[{"id":"x"},{"id":"y"},{"title":"no id"}]}"#
        XCTAssertEqual(WavlakeAPI.albumIds(fromArtist: Data(json.utf8)), ["x", "y"])
    }

    func testGarbageIsEmptyNotACrash() {
        XCTAssertTrue(WavlakeAPI.tracks(fromRankings: Data("<html>".utf8)).isEmpty)
        XCTAssertTrue(WavlakeAPI.results(fromSearch: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(WavlakeAPI.tracks(fromAlbum: Data("[]".utf8)).isEmpty)
    }

    func testSearchURLEscapesTheTerm() {
        XCTAssertEqual(WavlakeAPI.searchURL("rock & roll")?.absoluteString,
                       "https://wavlake.com/api/v1/content/search?term=rock%20%26%20roll")
    }
}

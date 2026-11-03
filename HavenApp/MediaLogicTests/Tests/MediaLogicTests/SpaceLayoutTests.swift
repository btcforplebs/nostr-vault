import XCTest
@testable import MediaLogic

/// The shared rail + Your space layout (docs/SPACE_LAYOUT.md). The web's
/// space-layout.test.mjs covers the same panel rules.
final class SpaceLayoutTests: XCTestCase {
    private let sections = ["feed", "search", "profile", "wot", "vault"]
    private let panelIds = ["live-vault", "wot-mini", "messages"]
    private let pk = String(repeating: "ab", count: 32)

    private func parse(_ json: String) -> SpaceLayout? {
        SpaceLayout.decode(Data(json.utf8), sections: sections, panelIds: panelIds)
    }

    private func ids(_ layout: SpaceLayout) -> [String] { layout.pins.map(\.id) }

    func testGarbageGivesTheDefault() {
        let layout = parse("not json")!
        XCTAssertEqual(layout.pins.map(\.id), SpaceLayout.allSections.map { "section:\($0)" })
        XCTAssertEqual(layout.panels.map(\.id), panelIds)
        XCTAssertTrue(layout.panels.allSatisfy { $0.on && $0.open })
        XCTAssertEqual(layout.at, 0)
    }

    func testNewerVersionIsLeftAlone() {
        XCTAssertNil(parse(#"{"v":2,"pins":[],"panels":[]}"#))
    }

    func testVersionAndFlagsReadAsNumbersAndBools() {
        let layout = parse(#"{"v":1,"at":1700000000,"pins":[],"panels":[{"id":"wot-mini","on":false,"open":false}]}"#)!
        XCTAssertEqual(layout.at, 1_700_000_000)
        let wot = layout.panels.first { $0.id == "wot-mini" }!
        XCTAssertFalse(wot.on)
        XCTAssertFalse(wot.open)
    }

    func testMissingSectionsGoBackAtTheirDefaultPlace() {
        let layout = parse(#"{"v":1,"pins":[{"type":"section","id":"vault"},{"type":"hashtag","t":"bitcoin"},{"type":"section","id":"search"}]}"#)!
        // feed has nothing before it: top. profile goes after search, wot after profile.
        XCTAssertEqual(ids(layout), ["section:feed", "section:vault", "hashtag:bitcoin", "section:search",
                                     "section:profile", "section:wot"])
    }

    func testValuesAreNormalisedAndBadOnesDrop() {
        let json = """
        {"v":1,"pins":[
          {"type":"hashtag","t":"#Bitcoin"},
          {"type":"hashtag","t":"bitcoin"},
          {"type":"person","p":"\(pk.uppercased())"},
          {"type":"person","p":"npub1nothex"},
          {"type":"relay","url":"wss://Relay.Example.com/"},
          {"type":"relay","url":"https://not-a-relay"},
          {"type":"list","a":"30000:\(pk):devs"},
          {"type":"list","a":"1:\(pk):x"},
          {"type":"hashtag"},
          "a string"
        ]}
        """
        let favourites = parse(json)!.pins.filter { !$0.isSection }
        XCTAssertEqual(favourites.map(\.kind), [.hashtag("bitcoin"), .person(pk), .relay("wss://relay.example.com"),
                                                .list("30000:\(pk):devs")])
    }

    func testUnknownEntriesAndKeysSurviveARoundTrip() {
        let json = #"{"v":1,"at":5,"theme":{"x":1},"pins":[{"type":"section","id":"notifications"},{"type":"board","id":"b1","w":2}],"panels":[{"id":"zaps","on":true,"open":true,"h":3}]}"#
        let layout = parse(json)!
        let again = SpaceLayout.decode(layout.encoded(), sections: sections, panelIds: panelIds)!
        XCTAssertEqual(again, layout)
        XCTAssertEqual(again.extra["theme"], .object(["x": .number(1)]))
        XCTAssertTrue(again.pins.contains { $0.raw["type"] == .string("board") && $0.raw["w"] == .number(2) })
        XCTAssertTrue(again.panels.contains { $0.id == "zaps" && $0.raw["h"] == .number(3) })
        // Kept, not drawn.
        XCTAssertFalse(again.shownPins(sections: sections).contains { $0.kind == .unknown })
        XCTAssertFalse(again.shownPins(sections: sections).contains { $0.kind == .section("notifications") })
        XCTAssertFalse(again.shownPanels(panelIds).contains { $0.id == "zaps" })
    }

    func testMissingPanelGoesAfterTheOneBeforeIt() {
        let layout = parse(#"{"v":1,"panels":[{"id":"messages","on":true,"open":true},{"id":"live-vault","on":false,"open":true}]}"#)!
        // wot-mini comes after live-vault in the default order.
        XCTAssertEqual(layout.panels.map(\.id), ["messages", "live-vault", "wot-mini"])
    }

    func testFavouritesCapAtThirty() {
        let pins = (0..<35).map { #"{"type":"hashtag","t":"t\#($0)"}"# }.joined(separator: ",")
        let layout = parse(#"{"v":1,"pins":[\#(pins)]}"#)!
        XCTAssertEqual(layout.favouriteCount, SpaceLayout.maxFavourites)
        XCTAssertNil(layout.addingPin(SpaceLayout.Pin.favourite(.hashtag("more"))!, at: 1))
    }

    func testAddRemoveAndSectionsStay() {
        var layout = SpaceLayout.defaultLayout(panelIds: panelIds)
        let tag = SpaceLayout.Pin.favourite(.hashtag("#Nostr"))!
        layout = layout.addingPin(tag, at: 10)!
        XCTAssertEqual(layout.at, 10)
        XCTAssertEqual(layout.pins.last?.kind, .hashtag("nostr"))
        XCTAssertNil(layout.addingPin(tag, at: 11), "the same favourite is in once")
        XCTAssertEqual(layout.removingPin("section:feed", at: 12), layout, "sections never go")
        layout = layout.removingPin(tag.id, at: 13)
        XCTAssertFalse(layout.pins.contains { $0.id == tag.id })
        XCTAssertNil(SpaceLayout.Pin.favourite(.person("nope")))
    }

    func testMovingPinsSkipsUndrawnOnes() {
        // notifications is not drawn here; it keeps its slot between the drawn pins.
        let layout = parse(#"{"v":1,"pins":[{"type":"section","id":"feed"},{"type":"section","id":"notifications"},{"type":"section","id":"search"},{"type":"hashtag","t":"a"}]}"#)!
        let shown = layout.shownPins(sections: sections).map(\.id)
        XCTAssertEqual(shown, ["section:feed", "section:search", "section:profile", "section:wot", "section:vault", "hashtag:a"])
        // Drag the hashtag to the top.
        let moved = layout.movingPins(from: IndexSet(integer: 5), to: 0, sections: sections, at: 20)
        XCTAssertEqual(Array(moved.pins.map(\.id).prefix(4)), ["hashtag:a", "section:notifications", "section:feed", "section:search"])
        XCTAssertEqual(moved.at, 20)
    }

    func testPanelEditsMoveAmongDrawnOnly() {
        var layout = SpaceLayout.defaultLayout(panelIds: panelIds)
        layout = layout.settingPanel("wot-mini", on: false, at: 1)
        XCTAssertEqual(layout.hiddenPanels(panelIds), ["wot-mini"])
        // messages moves up past the hidden wot-mini to the top of the drawn ones.
        layout = layout.movingPanel("messages", by: -1, ids: panelIds, at: 2)
        XCTAssertEqual(layout.shownPanels(panelIds).map(\.id), ["messages", "live-vault"])
        XCTAssertEqual(layout.movingPanel("messages", by: -1, ids: panelIds, at: 3), layout, "already at the top")
        layout = layout.settingPanel("messages", open: false, at: 4)
        XCTAssertFalse(layout.panels.first { $0.id == "messages" }!.open)
        let reset = layout.resettingPanels(panelIds: panelIds, at: 5)
        XCTAssertEqual(reset.panels.map(\.id), panelIds)
        XCTAssertTrue(reset.panels.allSatisfy { $0.on && $0.open })
    }

    func testNewerAtWinsAndATieKeepsTheDevice() {
        let local = SpaceLayout.defaultLayout(panelIds: panelIds, at: 100)
        XCTAssertTrue(SpaceLayout.remoteWins(remote: .defaultLayout(panelIds: panelIds, at: 101), local: local))
        XCTAssertFalse(SpaceLayout.remoteWins(remote: .defaultLayout(panelIds: panelIds, at: 100), local: local))
    }
}

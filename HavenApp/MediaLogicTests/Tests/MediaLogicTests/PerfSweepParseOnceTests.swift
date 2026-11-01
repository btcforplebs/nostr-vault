import XCTest
@testable import MediaLogic

/// Tom's perf sweep 11-01 #2, #4, #6: read once, decode once.
final class PerfSweepParseOnceTests: XCTestCase {
    func testGlobeFrameMatchesGlobeMessage() {
        let event = #"{"id":"x","pubkey":"y","kind":1,"content":"arcs-","tags":[]}"#
        let messages = [
            #"["EVENT","arcs-1a2b3c4d",\#(event)]"#, #"[ "EOSE", "arcs-9"]"#, #"["CLOSED","arcs-1","no"]"#,
            #"["EVENT","feed-x",\#(event)]"#, #"["NOTICE","arcs-x"]"#, #"["OK","arcs-1",true,""]"#, "[]", "",
        ]
        for message in messages {
            let frame = RelayFrame.parse(message)
            let viaFrame = frame.map { GlobeArcs.isGlobeFrame(type: $0.type, json: $0.json) } ?? false
            XCTAssertEqual(viaFrame, GlobeArcs.isGlobeMessage(message), message)
        }
        XCTAssertTrue(GlobeArcs.isGlobeFrame(type: "EVENT", json: ["EVENT", "arcs-1", [:] as [String: Any]]))
        XCTAssertFalse(GlobeArcs.isGlobeFrame(type: "EVENT", json: ["EVENT"]))
    }

    func testVouchesFromParsedCacheMatchFromData() throws {
        let data = Data(#"{"pubkeys":{"a":true},"vouches":{"a":3,"b":2.0,"c":"x"}}"#.utf8)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(TrustMap.vouches(fromJSON: json), ["a": 3, "b": 2])
        XCTAssertEqual(TrustMap.vouches(fromJSON: json), TrustMap.vouches(fromCache: data))
        XCTAssertNil(TrustMap.vouches(fromJSON: ["pubkeys": [:] as [String: Any]]))
    }

    func testNpubHexMemoDecodesAndFollowsChanges() throws {
        let a = try XCTUnwrap(Bech32.encode(hrp: "npub", data: Data(repeating: 1, count: 32)))
        let b = try XCTUnwrap(Bech32.encode(hrp: "npub", data: Data(repeating: 2, count: 32)))
        let hexA = String(repeating: "01", count: 32), hexB = String(repeating: "02", count: 32)
        let memo = NpubHexMemo()
        XCTAssertEqual(memo.hexSet([a, " ", "junk"]), [hexA])
        XCTAssertEqual(memo.hexSet([a, " ", "junk"]), [hexA], "same list again")
        XCTAssertEqual(memo.hexSet([a, " \(b)\n"]), [hexA, hexB], "a changed list is decoded again")
        XCTAssertEqual(memo.hexSet([]), [])
        XCTAssertEqual(memo.hex(a), hexA)
        XCTAssertEqual(memo.hex(" \(b) "), hexB)
        XCTAssertNil(memo.hex("junk"))
        XCTAssertEqual(NpubHexMemo.decode([a, b]), [hexA, hexB])
    }

    /// The hot paths read the memos and parse each feed message once.
    func testHotPathsUseTheOnePassVersions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../HavenApp").standardized
        func src(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let sub = try src("Services/Feed/FeedService+FeedSubscription.swift")
        XCTAssertFalse(sub.contains("handleExternalEventInjection"))
        XCTAssertEqual(sub.components(separatedBy: "handleFeedRelayMessage(msg, totalRelays: totalRelays, inject: !isLocalRelay)").count - 1, 3)
        let batching = try src("Services/Feed/FeedService+NoteBatching.swift")
        XCTAssertFalse(batching.contains("GlobeArcs.isGlobeMessage(msg)"))
        XCTAssertFalse(batching.contains("verifiedParentEvent(msg)"))
        let inject = try src("Services/Feed/FeedService+LocalRelayInjection.swift")
        XCTAssertFalse(inject.contains("Bech32.decode(config.ownerNpub)"))
        let config = try src("Services/ConfigService.swift")
        XCTAssertTrue(config.contains("Self.blockedMemo.hexSet(blockedNpubs)"))
        XCTAssertTrue(config.contains("Self.whitelistedMemo.hexSet(config.whitelistedNpubs)"))
        let haze = try src("Views/TrustWeb/TrustWebView+FacesAndFilters.swift")
        XCTAssertFalse(haze.contains("relayTabTrustedPubkeys()"))
        XCTAssertTrue(haze.contains("await feed.loadWotPubkeysInBackgroundIfChanged()"))
    }
}

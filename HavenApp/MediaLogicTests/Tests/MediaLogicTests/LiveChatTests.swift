import XCTest
@testable import MediaLogic

final class LiveChatTests: XCTestCase {
    private let host = String(repeating: "a1", count: 32)
    private let service = String(repeating: "b2", count: 32)
    private let payer = String(repeating: "c3", count: 32)

    private func zapRequestJSON(pubkey: String, content: String, amountMsat: String?) -> String {
        var tags: [[String]] = [["p", host]]
        if let amountMsat { tags.append(["amount", amountMsat]) }
        let object: [String: Any] = ["pubkey": pubkey, "content": content, "tags": tags]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Addressing

    func testAddressIsTheStreamCoordinate() {
        XCTAssertEqual(LiveChat.address(hostPubkey: host, identifier: "abc"), "30311:\(host):abc")
    }

    /// zap.stream publishes a stream on the host's behalf. Paying the author
    /// would pay zap.stream.
    func testHostComesFromTheHostRoleTagWhenTheStreamWasPublishedByAService() {
        let tags = [["p", payer, "", "Speaker"], ["p", host, "wss://relay.zap.stream", "Host"]]
        XCTAssertEqual(LiveChat.hostPubkey(authorPubkey: service, tags: tags), host)
    }

    func testHostFallsBackToTheAuthorWhenNobodyIsTaggedHost() {
        XCTAssertEqual(LiveChat.hostPubkey(authorPubkey: host, tags: [["p", payer, "", "Speaker"]]), host)
        XCTAssertEqual(LiveChat.hostPubkey(authorPubkey: host, tags: []), host)
    }

    // MARK: - Following

    /// shosho.live signs every stream with its own key (85df822a…) and names
    /// the streamer only as `Host`. Tags are from a real one, 2026-09-26.
    func testAFollowedHostsServicePublishedStreamIsFollowed() {
        let tags = [
            ["d", "4dbfc337-fbc2-4cb3-b454-93a6e1cefde0"],
            ["status", "live"],
            ["p", host, "", "host"],
            ["service", "https://api.shosho.live/api/v1"],
        ]
        XCTAssertTrue(LiveChat.isFollowed(authorPubkey: service, tags: tags, follows: [host]))
        XCTAssertFalse(LiveChat.isFollowed(authorPubkey: service, tags: tags, follows: [payer]))
    }

    func testAStreamTheOwnerFollowsTheAuthorOfIsFollowed() {
        XCTAssertTrue(LiveChat.isFollowed(authorPubkey: host, tags: [], follows: [host]))
    }

    /// A `#p` query also returns streams a followed pubkey only guests on.
    func testAFollowedGuestDoesNotMakeTheStreamFollowed() {
        let tags = [["p", payer, "", "Speaker"], ["p", host, "", "Host"]]
        XCTAssertFalse(LiveChat.isFollowed(authorPubkey: service, tags: tags, follows: [payer]))
    }

    // MARK: - On air

    private let t0: Int64 = 1_790_000_000

    func testALiveEventUpdatedWithinTheHourIsOnAir() {
        XCTAssertTrue(LiveChat.isOnAir(status: "live", createdAt: t0, ends: nil, now: t0 + 3600))
        XCTAssertTrue(LiveChat.isOnAir(status: nil, createdAt: t0, ends: nil, now: t0 + 60))
    }

    /// Seen 2026-09-26: `live` events 6h to 111h old, every URL a 404.
    func testALiveEventNobodyHasUpdatedForAnHourIsOffAir() {
        XCTAssertFalse(LiveChat.isOnAir(status: "live", createdAt: t0, ends: nil, now: t0 + 3601))
    }

    func testAStreamPastItsEndsTimeOrEndedIsOffAir() {
        XCTAssertFalse(LiveChat.isOnAir(status: "live", createdAt: t0, ends: t0 + 10, now: t0 + 10))
        XCTAssertFalse(LiveChat.isOnAir(status: "ended", createdAt: t0, ends: nil, now: t0))
    }

    func testOnlyAnHLSPlaylistIsAPlayableStreamURL() {
        let playable = [
            "https://customer-51tzzrmdygiq19h7.cloudflarestream.com/b919559ef7b1b5512b83d273bf8cb363/manifest/video.m3u8",
            "https://api.streamroad.money/x/hls/live.m3u8?token=abc",
        ]
        for raw in playable { XCTAssertTrue(LiveChat.isPlayableStreamURL(URL(string: raw)!), raw) }
        // A youtube.com/live page was in a real `streaming` tag.
        let unplayable = ["https://youtube.com/live/YbnlF1CRqok", "rtmp://e/live.m3u8", "https://e/watch?v=x.m3u8"]
        for raw in unplayable { XCTAssertFalse(LiveChat.isPlayableStreamURL(URL(string: raw)!), raw) }
    }

    // MARK: - Where the chat is

    /// zap.stream is the documented relay and, measured across every live
    /// stream on 2026-09-07, carries none of the chat. It stays in the list
    /// because it is the address other clients look for, but it is asked last.
    func testChatRelaysPreferTheStreamsOwnAnswerAndNeverLeadWithZapStream() {
        let ordered = LiveChat.chatRelays(streamRelays: ["wss://relay.snort.social"],
                                          userRelays: ["wss://my.relay"])
        XCTAssertEqual(ordered.first, "wss://relay.snort.social")
        XCTAssertEqual(Array(ordered.dropFirst(1).prefix(3)), LiveChat.defaultChatRelays)
        XCTAssertEqual(ordered.last, "wss://my.relay")
        // Five sockets is the budget, and zap.stream is the first thing cut:
        // it is asked only when nothing better filled the list.
        XCTAssertFalse(ordered.contains(LiveChat.streamRelay))
        XCTAssertEqual(LiveChat.chatRelays(streamRelays: [], userRelays: []).last, LiveChat.streamRelay)
    }

    /// Hosts advertise both forms. Two sockets to one relay prints every
    /// message twice.
    func testTrailingSlashAndCaseDoNotOpenTheSameRelayTwice() {
        let ordered = LiveChat.chatRelays(streamRelays: ["wss://nos.lol/", "WSS://NOS.LOL"],
                                          userRelays: [], limit: 10)
        XCTAssertEqual(ordered.filter { $0.lowercased().contains("nos.lol") }.count, 1)
        XCTAssertEqual(ordered.first, "wss://nos.lol")
    }

    func testChatRelaysDropUnusableEntriesAndRespectTheLimit() {
        let ordered = LiveChat.chatRelays(streamRelays: ["", "https://example.com", "not a url"],
                                          userRelays: ["wss://a.relay", "wss://b.relay"], limit: 3)
        XCTAssertEqual(ordered.count, 3)
        XCTAssertEqual(ordered, LiveChat.defaultChatRelays)
        XCTAssertNil(LiveChat.normalizedRelay("https://example.com"))
        XCTAssertEqual(LiveChat.normalizedRelay(" wss://relay.example.com/ "), "wss://relay.example.com")
    }

    // MARK: - Chat messages

    func testChatMessageKeepsItsAuthorAndText() {
        let message = LiveChat.message(id: "1", pubkey: payer, kind: 1311, createdAt: 100,
                                       content: "  gm  ", tags: [["a", "30311:x:y"]])
        XCTAssertEqual(message?.authorPubkey, payer)
        XCTAssertEqual(message?.text, "gm")
        XCTAssertFalse(message?.isZap ?? true)
    }

    func testEmptyAndUnknownKindsAreDropped() {
        XCTAssertNil(LiveChat.message(id: "1", pubkey: payer, kind: 1311, createdAt: 1, content: "   ", tags: []))
        XCTAssertNil(LiveChat.message(id: "1", pubkey: payer, kind: 1, createdAt: 1, content: "hi", tags: []))
        XCTAssertNil(LiveChat.message(id: "", pubkey: payer, kind: 1311, createdAt: 1, content: "hi", tags: []))
    }

    // MARK: - Zap receipts

    /// The receipt is signed by the LNURL provider, so attributing the row to
    /// its pubkey credits the payment processor instead of the person.
    func testZapIsAttributedToThePayerFromTheEmbeddedRequest() {
        let tags = [["description", zapRequestJSON(pubkey: payer, content: "nice stream", amountMsat: "21000")]]
        let message = LiveChat.message(id: "z", pubkey: service, kind: 9735, createdAt: 5,
                                       content: "", tags: tags)
        XCTAssertEqual(message?.authorPubkey, payer)
        XCTAssertEqual(message?.zapSats, 21)
        XCTAssertEqual(message?.text, "nice stream")
    }

    func testZapWithoutADescriptionFallsBackToTheCapitalPTagThenTheReceipt() {
        let withP = LiveChat.message(id: "z", pubkey: service, kind: 9735, createdAt: 5, content: "",
                                     tags: [["P", payer], ["amount", "5000"]])
        XCTAssertEqual(withP?.authorPubkey, payer)
        XCTAssertEqual(withP?.zapSats, 5)

        let bare = LiveChat.message(id: "z", pubkey: service, kind: 9735, createdAt: 5, content: "", tags: [])
        XCTAssertEqual(bare?.authorPubkey, service)
        XCTAssertEqual(bare?.zapSats, 0)
    }

    /// Providers have been seen copying the request through a channel that
    /// leaves raw control bytes in the string; JSONSerialization refuses those.
    func testZapRequestWithControlCharactersStillParses() {
        let dirty = zapRequestJSON(pubkey: payer, content: "hi", amountMsat: "1000")
            .replacingOccurrences(of: "\"hi\"", with: "\"h\u{0007}i\"")
        let message = LiveChat.message(id: "z", pubkey: service, kind: 9735, createdAt: 5,
                                       content: "", tags: [["description", dirty]])
        XCTAssertEqual(message?.authorPubkey, payer)
        XCTAssertEqual(message?.text, "hi")
    }

    // MARK: - Amounts

    /// The one that matters for live: zap.stream receipts routinely carry the
    /// invoice and nothing else, and a stream chat full of "⚡ 0" is useless.
    func testAmountFallsBackToTheInvoiceWhenNoTagCarriesIt() {
        let tags = [["bolt11", "lnbc2500u1pvjluezpp5abcdef"],
                    ["description", zapRequestJSON(pubkey: payer, content: "", amountMsat: nil)]]
        XCTAssertEqual(LiveChat.message(id: "z", pubkey: service, kind: 9735, createdAt: 5,
                                        content: "", tags: tags)?.zapSats, 250_000)
    }

    func testBolt11Multipliers() {
        XCTAssertEqual(LiveChat.satsFromBolt11("lnbc2500u1pvjluez"), 250_000)
        XCTAssertEqual(LiveChat.satsFromBolt11("lnbc10n1pvjluez"), 1)
        XCTAssertEqual(LiveChat.satsFromBolt11("lnbc1m1pvjluez"), 100_000)
        XCTAssertEqual(LiveChat.satsFromBolt11("LNBC1P1PVJLUEZ"), nil)   // 1 pico-BTC rounds under a sat
        XCTAssertEqual(LiveChat.satsFromBolt11("lntb20m1pvjluez"), 2_000_000)
        XCTAssertNil(LiveChat.satsFromBolt11("lnbc1pvjluez"))            // amountless invoice
        XCTAssertNil(LiveChat.satsFromBolt11("not-an-invoice"))
    }

    /// An amountless invoice ("pay me what you like") is legal and zap
    /// receipts do carry them. The digits after `lnbc` in one of those are not
    /// an amount — they are the bech32 separator and the start of the data
    /// part. Reading them as an amount invents a number, and because bech32's
    /// charset contains `m`/`u`/`n`/`p`, which number it invents depends on
    /// the random first character of the payload.
    func testAmountlessInvoicesReportNothingWhateverTheDataStartsWith() {
        // Data part starting with an ordinary bech32 character: this used to
        // read as 1 whole BTC.
        XCTAssertNil(LiveChat.satsFromBolt11("lnbc1qqqqsyqcyq5rqwzqfqypqdq5"))
        // Data part starting with a multiplier letter: 1 micro-BTC, 100 sats.
        XCTAssertNil(LiveChat.satsFromBolt11("lnbc1u3qqqsyqcyq5rqwzqfqypq"))
        XCTAssertNil(LiveChat.satsFromBolt11("lnbc1n3qqqsyqcyq5rqwzqfqypq"))
        XCTAssertNil(LiveChat.satsFromBolt11("lntb1qqqqsyqcyq5rqwzqfqypqdq5"))
    }

    /// The digit run comes off the wire unbounded, and `*` traps on overflow
    /// in Swift — a hostile invoice must return nil, not kill the app.
    func testAbsurdAmountsDoNotTrap() {
        XCTAssertNil(LiveChat.satsFromBolt11("lnbc99999999999999999m1pvjluez"))
        XCTAssertNil(LiveChat.satsFromBolt11("lnbc999999999999999999999999991pvjluez"))
        // 21 million BTC is the whole supply; anything at or past it is junk.
        XCTAssertNil(LiveChat.satsFromBolt11("lnbc21000000001pvjluez"))
    }

    /// The bech32 separator is the *last* `1`, because the data charset has no
    /// `1` in it. Anchoring on the first one mis-splits any invoice whose
    /// amount contains a 1.
    func testAmountContainingAOneIsNotCutShort() {
        XCTAssertEqual(LiveChat.satsFromBolt11("lnbc1500n1pvjluez"), 150)
        XCTAssertEqual(LiveChat.satsFromBolt11("lnbc21u1pvjluez"), 2_100)
    }

    /// The request's own amount is the zapper's stated intent and wins over a
    /// receipt tag a relay may have added.
    func testRequestAmountBeatsReceiptAmount() {
        XCTAssertEqual(LiveChat.zapAmountSats(receiptTags: [["amount", "1000"]],
                                              requestTags: [["amount", "7000"]]), 7)
    }
}

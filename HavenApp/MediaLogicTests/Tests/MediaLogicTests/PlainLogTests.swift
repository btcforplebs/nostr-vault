import XCTest
@testable import MediaLogic

final class PlainLogTests: XCTestCase {
    private let hex = String(repeating: "ab", count: 32)

    private func entry(_ line: String) -> RelayLogParser.LogEntry {
        RelayLogParser.LogEntry.parse(line)
    }

    func testNoiseIsDropped() {
        let noise = [
            "2026/10/05 10:00:00 http: TLS handshake error from 192.168.1.20:51234: EOF",
            "badger 2026/10/05 10:00:00 INFO: Set nextTxnTs to 42",
            "  \"AllowEmptyFilters\": true,",
            "{",
            "🔔NOTIFY|type=reaction|kind=7|author=\(hex)|id=\(hex)|recipient=\(hex)|",
            "WARN negentropy sync failed, plain catch-up this round relay=wss://relay.example.com err=\"x\"",
            "INFO event stored",
        ]
        for line in noise {
            let e = entry(line)
            XCTAssertNil(PlainLog.translate(level: e.level, message: e.message), line)
        }
    }

    func testRemoteRelayFailuresGroupPerHost() {
        let line = "2026/10/05 10:00:00 ERROR ⛓️‍💥 error connecting to relay relay=wss://relay.damus.io error=\"failed to connect\""
        let items = PlainLog.summarize([entry(line), entry(line), entry(line)])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].count, 3)
        XCTAssertEqual(items[0].severity, .headsUp)
        XCTAssertEqual(items[0].title, "Couldn't reach relay.damus.io")
    }

    func testMembersOnlyRelay() {
        let e = entry("2026/10/05 10:00:00 ERROR 🚫 error publishing to relay relay=wss://nostr.wine error=\"msg: restricted: sign up at https://nostr.wine\"")
        let msg = PlainLog.translate(level: e.level, message: e.message)
        XCTAssertEqual(msg?.title, "nostr.wine only accepts posts from its members")
    }

    func testLockedDatabaseIsAProblem() {
        let e = entry("2026/10/05 10:00:00 ERROR Cannot acquire directory lock on \"/Users/me/db\"")
        XCTAssertEqual(PlainLog.translate(level: e.level, message: e.message)?.severity, .problem)
    }

    func testUnknownErrorSurfacesScrubbed() {
        let msg = PlainLog.translate(level: "ERROR", message: "boom for npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m at /Users/me/x")
        XCTAssertEqual(msg?.severity, .problem)
        XCTAssertFalse(msg!.title.contains("npub1"))
        XCTAssertFalse(msg!.title.contains("/Users"))
    }

    func testUnknownInfoIsHidden() {
        XCTAssertNil(PlainLog.translate(level: "INFO", message: "something routine happened"))
    }

    func testRepeatMovesToEnd() {
        let a = entry("📰 new note in your inbox")
        let b = entry("⚡️ new zap in your inbox")
        let items = PlainLog.summarize([a, b, a])
        XCTAssertEqual(items.map(\.key), ["new-zap", "new-mention"])
        XCTAssertEqual(items.last?.count, 2)
    }

    func testHealthIgnoresProblemsBeforeLastStart() {
        let t0 = Date(timeIntervalSince1970: 0)
        let problem = PlainLog.Item(key: "db-locked", severity: .problem, title: "", hint: nil, count: 1, firstSeen: t0, lastSeen: t0)
        let up = PlainLog.Item(key: "running", severity: .good, title: "", hint: nil, count: 1, firstSeen: t0, lastSeen: t0.addingTimeInterval(10))
        XCTAssertEqual(PlainLog.health([problem, up]), .good)
        XCTAssertEqual(PlainLog.health([problem]), .problem)
    }

    func testScrubRemovesSecrets() {
        let raw = """
        nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5 \
        npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m \
        id=\(hex) from 10.0.0.12:4869 and [fe80::1c2b:3cff:fe4d:5e6f]:443 \
        me@example.com /var/mobile/Containers/Data/x.db \
        nostr+walletconnect://abc?relay=wss://r.example&secret=\(hex) \
        https://cdn.example.com/u/abc.jpg?token=SECRET wss://relay.damus.io/path \
        wss://abcdefghijklmnop.onion ws://haven.local:3355 wss://box.tail1234.ts.net ws://localhost:4869 ws://umbrel:4848
        """
        let out = PlainLog.scrub(raw)
        for leak in ["nsec1", "npub1", hex, "10.0.0.12", "fe80", "me@example.com", "/var/mobile",
                     "walletconnect", "SECRET", "abc.jpg", "/path",
                     "abcdefghijklmnop", "haven.local", "tail1234", "localhost", "umbrel"] {
            XCTAssertFalse(out.contains(leak), "leaked \(leak) in: \(out)")
        }
        // Positive control: relay hosts survive, they make the report useful.
        XCTAssertTrue(out.contains("wss://relay.damus.io"))
        XCTAssertTrue(out.contains("https://cdn.example.com"))
        XCTAssertTrue(out.contains("wss://[private-relay]"))
        XCTAssertEqual(PlainLog.relayHost(in: "relay=ws://umbrel:4848 x"), "a private relay")
        XCTAssertEqual(PlainLog.relayHost(in: "relay=wss://nos.lol x"), "nos.lol")
    }

    func testExportHasNoRawLines() {
        let items = PlainLog.summarize([
            entry("2026/10/05 10:00:00 ERROR boom npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"),
            entry("🔗 listening at https://192.168.1.5:4869"),
        ])
        let text = PlainLog.exportText(items, header: ["App: 2.7.2 (19)"])
        XCTAssertTrue(text.contains("Relay is running"))
        XCTAssertTrue(text.contains("App: 2.7.2 (19)"))
        XCTAssertFalse(text.contains("npub1"))
        XCTAssertFalse(text.contains("192.168"))
    }
}

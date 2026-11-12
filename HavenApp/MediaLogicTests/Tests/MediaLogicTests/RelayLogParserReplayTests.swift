import XCTest
@testable import MediaLogic

/// The parser's one cheap check per line and byte search (2026-11-12) must
/// give the same state as before for every line. Replays relay logs through
/// LegacyRelayLogParser (master 4022960f, frozen) and the current parser and
/// compares the batch line by line.
///
/// The committed fixture is up to three lines per template from two phone
/// relay logs, anonymised. Set NV_RELAY_LOG_REPLAY to colon-separated paths of
/// whole relay logs to replay those too (they hold private data, so they are
/// never committed).
final class RelayLogParserReplayTests: XCTestCase {
    static func signature(_ b: RelayLogParser.BatchedStateUpdate) -> String {
        Mirror(reflecting: b).children.map { child -> String in
            let value: String
            if let kinds = child.value as? Set<Int> {
                value = "\(kinds.sorted())"
            } else {
                value = String(describing: child.value)
            }
            return "\(child.label ?? "?")=\(value)"
        }.joined(separator: " ")
    }

    private func replay(_ lines: [String], file: String) -> Int {
        var compared = 0
        for (n, line) in lines.enumerated() where !line.isEmpty {
            var old = RelayLogParser.BatchedStateUpdate()
            LegacyRelayLogParser.collectStateChanges(from: line, into: &old)
            var new = RelayLogParser.BatchedStateUpdate()
            RelayLogParser.collectStateChanges(from: line, into: &new)
            let o = Self.signature(old), c = Self.signature(new)
            if o != c {
                XCTFail("\(file):\(n + 1) differs\n line: \(line.prefix(200))\n old: \(o)\n new: \(c)")
                return compared
            }
            compared += 1
        }
        return compared
    }

    func testCommittedPhoneLogTemplatesGiveTheSameState() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "phone-templates", withExtension: "log",
                                                  subdirectory: "Fixtures/RelayLog"))
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertGreaterThan(replay(lines, file: "phone-templates.log"), 2_000)
    }

    func testWholePrivateLogsGiveTheSameState() throws {
        guard let paths = ProcessInfo.processInfo.environment["NV_RELAY_LOG_REPLAY"], !paths.isEmpty else {
            throw XCTSkip("NV_RELAY_LOG_REPLAY not set")
        }
        for path in paths.split(separator: ":").map(String.init) {
            let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
            let n = replay(text.components(separatedBy: "\n"), file: path)
            print("replayed \(n) lines of \(path)")
        }
    }

    /// The relay's own lines in the shapes it writes now, including the ones
    /// the fast path takes.
    func testCurrentRelayLineShapesGiveTheSameState() {
        let ts = "2026/11/12 03:10:00 "
        let id = String(repeating: "ab", count: 32)
        let lines = [
            "INFO event stored",
            "INFO 🔫 blasted event id=\(id) kind=1 relays=5 rejected=0 failed=2",
            "INFO 🔫 blasted event id=\(id) kind=30023 relays=0 rejected=3 failed=0",
            "📰 new note in your inbox",
            "❤️ new reaction in your inbox",
            "🤙 new reaction in your inbox",
            "⚡️ new zap in your inbox",
            "🔒✉️ new encrypted message in your inbox",
            "🎁🔒️✉️ new gift-wrapped message in your chat relay",
            "🔁 new repost in your inbox",
            "📦 new event kind 30023 event in your inbox",
            "🔔NOTIFY|type=reply|kind=1|author=\(id)|id=\(id)|recipient=\(id)|recipients=\(id)|preview=starting to listen on the disconnected relay",
            "🔔NOTIFY|type=listversion|kind=3|author=\(id)|id=\(id)|recipient=\(id)|recipients=\(id)|preview=",
            "🔗 relay listening at :3355",
            "📢 subscribing to inbox on 4 relays (import + DM)",
            "RELAY_START_FAILED| port in use",
            "listen tcp :3355: bind: address already in use",
            "Cannot acquire directory lock on \"x\". Another process is using this Badger database.",
            "IMPORT_JOB name=first-run status=done stored=12 unread=3",
            "COPY stage=pull part=notes bytes=10 items=2 source=mesh",
            "📜 looking for older versions of your lists",
            "NIP46SignEventC: sending sign_event to bunker kind=3 pubkey=0a1b2c3d tags=2000",
            "INFO 🛜 fetching Nostr events to build WoT",
            "INFO 🕸️ analysed Nostr events count=1234",
            "📦 Imported 40 notes from 2026-01-01 to 2026-01-10 (relay.example, negentropy)",
        ]
        XCTAssertEqual(replay(lines.map { ts + $0 } + lines, file: "shapes"), lines.count * 2)
    }

    /// Random hex and counts in the fast-path templates never change the
    /// answer.
    func testFastPathTemplatesWithRandomFieldsGiveTheSameState() {
        var lines: [String] = []
        for _ in 0..<500 {
            let id = (0..<64).map { _ in "0123456789abcdef".randomElement()! }.map(String.init).joined()
            lines.append("2026/11/12 03:10:00 INFO 🔫 blasted event id=\(id) kind=\(Int.random(in: 0...40000)) relays=\(Int.random(in: 0...20)) rejected=\(Int.random(in: 0...20)) failed=\(Int.random(in: 0...20))")
        }
        XCTAssertEqual(replay(lines, file: "random"), lines.count)
    }
}

/// The parser kept a full core busy on Logen's .99 Mac: ~50 Foundation
/// substring searches per line, each walking grapheme clusters on the emoji
/// in the relay's lines (2026-11-12 sample).
final class RelayLogParserSpeedTests: XCTestCase {
    func testTheBulkLinesParseAtLeastFiveTimesFasterThanBefore() {
        let id = String(repeating: "ab", count: 32)
        let bulk = [
            "2026/11/12 03:10:00 INFO event stored",
            "2026/11/12 03:10:00 INFO 🔫 blasted event id=\(id) kind=1 relays=5 rejected=0 failed=2",
            "2026/11/12 03:10:00 📰 new note in your inbox",
            "2026/11/12 03:10:00 ❤️ new reaction in your inbox",
            "2026/11/12 03:10:00 🔔NOTIFY|type=reply|kind=1|author=\(id)|id=\(id)|recipient=\(id)|recipients=\(id)|preview=gm friends",
            "2026/11/12 03:10:00 📥 negentropy inbox sync wss://relay.example.com: 3 new (local set 12000)",
        ]
        let lines = Array(repeating: bulk, count: 400).flatMap { $0 }

        func time(_ parse: (String, inout RelayLogParser.BatchedStateUpdate) -> Void) -> TimeInterval {
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let start = Date()
                var batch = RelayLogParser.BatchedStateUpdate()
                for line in lines { parse(line, &batch) }
                best = min(best, Date().timeIntervalSince(start))
            }
            return best
        }
        let old = time { LegacyRelayLogParser.collectStateChanges(from: $0, into: &$1) }
        let new = time { RelayLogParser.collectStateChanges(from: $0, into: &$1) }
        print("RelayLogParser speed: legacy \(Int(old * 1000)) ms, current \(Int(new * 1000)) ms for \(lines.count) lines")
        XCTAssertLessThan(new * 5, old, "current \(new) s vs legacy \(old) s")
    }
}

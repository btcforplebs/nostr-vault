import Foundation

/// Cheap byte-level reads for RelayLogParser.
///
/// The parser kept a full core busy on Logen's .99 Mac (2026-11-12): each of
/// its ~50 checks per line was a Foundation `contains` / `range(of:)`, which
/// walks grapheme clusters, and the relay's lines are full of emoji. These
/// compare UTF-8 bytes instead (`memmem`). Every needle the parser uses is
/// plain text, so a byte match is the same answer.
enum RelayLogBytes {
    /// Whether `needle`'s UTF-8 bytes occur in `hay`'s.
    static func contains(_ hay: String, _ needle: String) -> Bool {
        var hay = hay, needle = needle
        return hay.withUTF8 { h in
            needle.withUTF8 { n in
                guard !n.isEmpty else { return true }
                guard h.count >= n.count, let hb = h.baseAddress, let nb = n.baseAddress else { return false }
                return memmem(hb, h.count, nb, n.count) != nil
            }
        }
    }

    /// `line` with ASCII A-Z folded to a-z, everything else as it is. The
    /// parser's lowercase checks only look for ASCII words.
    static func asciiLowercased(_ line: String) -> String {
        var line = line
        return line.withUTF8 { bytes in
            String(unsafeUninitializedCapacity: bytes.count) { out in
                for (i, b) in bytes.enumerated() { out[i] = (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b }
                return bytes.count
            }
        }
    }

    /// Bytes of the relay's `yyyy/mm/dd hh:mm:ss ` prefix, or 0 if the line
    /// doesn't start with one.
    static func timestampLength(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        let shape = Array("dddd/dd/dd dd:dd:dd ".utf8)
        guard bytes.count >= shape.count else { return 0 }
        for (i, s) in shape.enumerated() {
            let b = bytes[i]
            let ok = s == UInt8(ascii: "d") ? (b >= 0x30 && b <= 0x39) : b == s
            if !ok { return 0 }
        }
        return shape.count
    }
}

extension RelayLogParser {
    /// Lines the relay writes once per event, in the exact shape it writes
    /// them, and what the full parse makes of each (filled from
    /// `collectStateChanges` itself, so the two can't disagree).
    private static let exactTemplates: [(bytes: [UInt8], batch: BatchedStateUpdate)] = [
        "INFO event stored",
        "📰 new note in your inbox",
        "❤️ new reaction in your inbox",
        "⚡️ new zap in your inbox",
        "🔒✉️ new encrypted message in your inbox",
        "🎁🔒️✉️ new gift-wrapped message in your chat relay",
        "🔁 new repost in your inbox",
    ].map { line in
        var batch = BatchedStateUpdate()
        fullStateChanges(from: line, into: &batch)
        return (Array(line.utf8), batch)
    }

    private static let blastedPrefix = Array("INFO 🔫 blasted event ".utf8)
    private static let blastedBatch: BatchedStateUpdate = {
        var batch = BatchedStateUpdate()
        fullStateChanges(from: "INFO 🔫 blasted event id=0 kind=1 relays=1 rejected=0 failed=0", into: &batch)
        return batch
    }()

    /// The one cheap check per line: if the text after the timestamp is one
    /// of the per-event lines (exactly, or a "blasted event" line whose tail
    /// is only `key=value` words of lowercase letters and digits), add what
    /// the full parse would add and return true. Anything else: false, and
    /// the line takes the full parse.
    static func fastStateChanges(from line: String, into batch: inout BatchedStateUpdate) -> Bool {
        var line = line
        let hit: BatchedStateUpdate? = line.withUTF8 { bytes in
            let start = RelayLogBytes.timestampLength(bytes)
            let message = UnsafeBufferPointer(rebasing: bytes[start...])
            for t in exactTemplates where t.bytes.count == message.count {
                if t.bytes.withUnsafeBufferPointer({ memcmp($0.baseAddress!, message.baseAddress!, message.count) == 0 }) {
                    return t.batch
                }
            }
            if message.count > blastedPrefix.count,
               blastedPrefix.withUnsafeBufferPointer({ memcmp($0.baseAddress!, message.baseAddress!, $0.count) == 0 }),
               message[blastedPrefix.count...].allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x3D || $0 == 0x20 }) {
                return blastedBatch
            }
            return nil
        }
        guard let hit else { return false }
        batch.eventsStoredDelta += hit.eventsStoredDelta
        batch.inboxActivityKinds.formUnion(hit.inboxActivityKinds)
        return true
    }
}

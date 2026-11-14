import Foundation

/// A GIF with nothing in it but its picture (DM privacy, Tron 2026-11-14; the twin of web-vault `net/gif-strip.js`).
/// A GIF can carry comments, XMP (where and with what it was made), ICC and Photoshop blocks and plain-text captions,
/// and a redraw would lose them but also the animation. So it is rebuilt block by block instead: header, screen and
/// colour table, each frame with its graphic control (delay, transparency) and the NETSCAPE loop count, rewritten from
/// the number alone. Everything else, and anything after the trailer, is left behind. A GIF that doesn't parse to the
/// end is refused, never sent as it is. Same bytes out as the web for the same GIF in.
enum GIFStrip {
    struct NotAWholeGIF: Error {}

    static func isGIF(_ data: Data) -> Bool { data.prefix(4).elementsEqual([0x47, 0x49, 0x46, 0x38]) }

    /// The GIF's bytes with only its frames, their timing and its loop count. Throws when it isn't a whole GIF.
    static func strip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 13 else { throw NotAWholeGIF() }
        let sig = String(decoding: b[0..<6], as: UTF8.self)
        guard sig == "GIF87a" || sig == "GIF89a" else { throw NotAWholeGIF() }
        var i = 13
        if b[10] & 0x80 != 0 { i += 3 * (1 << (Int(b[10] & 7) + 1)) } // global colour table
        guard b.count >= i else { throw NotAWholeGIF() }
        var out = Data(capacity: b.count)
        out.append(contentsOf: b[0..<i])

        /// Sub-blocks from `at`: the index after the 0 terminator, and the first `keep` data bytes.
        func blocks(_ start: Int, keep: Int = 0) throws -> (end: Int, data: [UInt8]) {
            var at = start
            var data: [UInt8] = []
            while true {
                guard at < b.count else { throw NotAWholeGIF() }
                let n = Int(b[at]); at += 1
                if n == 0 { return (at, data) }
                guard at + n <= b.count else { throw NotAWholeGIF() }
                if data.count < keep { data.append(contentsOf: b[at..<min(at + n, at + keep - data.count)]) }
                at += n
            }
        }

        var control: ArraySlice<UInt8>? = nil // a graphic control waits for what it controls
        var looped = false, frames = 0
        while true {
            guard i < b.count else { throw NotAWholeGIF() }
            let kind = b[i]
            if kind == 0x3b { out.append(0x3b); break }
            if kind == 0x2c {
                guard i + 10 <= b.count else { throw NotAWholeGIF() }
                var at = i + 10
                if b[i + 9] & 0x80 != 0 { at += 3 * (1 << (Int(b[i + 9] & 7) + 1)) } // local colour table
                at += 1 // LZW minimum code size
                guard at <= b.count else { throw NotAWholeGIF() }
                let end = try blocks(at).end
                if let c = control { out.append(contentsOf: c) }
                control = nil
                out.append(contentsOf: b[i..<end])
                frames += 1
                i = end
                continue
            }
            guard kind == 0x21, i + 2 <= b.count else { throw NotAWholeGIF() }
            let label = b[i + 1]
            let (end, data) = try blocks(i + 2, keep: label == 0xff ? 14 : 0)
            if label == 0xf9 {
                guard end - i == 8, b[i + 2] == 4 else { throw NotAWholeGIF() }
                control = b[i..<end]
            } else if label == 0x01 {
                control = nil // plain text: dropped, and its timing with it
            } else if label == 0xff, !looped, data.count >= 14 {
                let id = String(decoding: data[0..<11], as: UTF8.self)
                // The loop block: its first sub-block is 3 bytes, [1, loops lo, loops hi].
                if (id == "NETSCAPE2.0" || id == "ANIMEXTS1.0"), b[i + 2] == 11, b[i + 14] == 3, data[11] == 1 {
                    out.append(contentsOf: [0x21, 0xff, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, data[12], data[13], 0])
                    looped = true
                }
            }
            // 0xfe comments, every other application block (XMP, ICC, Photoshop, ...) and unknown labels: left behind.
            i = end
        }
        guard frames > 0 else { throw NotAWholeGIF() } // a GIF with no frame is no picture
        return out
    }
}

package com.nostrvault.service

import java.io.ByteArrayOutputStream

/**
 * A GIF with nothing in it but its picture (DM privacy, Tron 2026-11-14). Port of web
 * `web-vault/src/net/gif-strip.js` (#2075): the same input gives the same bytes.
 *
 * A GIF can carry comments, XMP (where and with what it was made), ICC and Photoshop blocks and
 * plain-text captions. A redraw would lose those but also the animation, so the file is rebuilt
 * block by block instead: header, screen and colour table, each frame with its graphic control
 * (delay, transparency) and the NETSCAPE loop count, rewritten from the number alone. Everything
 * else, and anything after the trailer, is left behind. A GIF that doesn't parse to the end is
 * refused, never sent as it is.
 */
object GifStrip {
    class NotAGif : Exception("not a whole GIF")

    /** A GIF by its own header, never by its type or name. */
    fun isGif(b: ByteArray): Boolean = b.size >= 4 && b[0] == 'G'.code.toByte() && b[1] == 'I'.code.toByte() &&
        b[2] == 'F'.code.toByte() && b[3] == '8'.code.toByte()

    /** The GIF's bytes with only its frames, their timing and its loop count. Throws [NotAGif]. */
    fun strip(b: ByteArray): ByteArray {
        if (b.size < 6) throw NotAGif()
        val sig = String(b, 0, 6, Charsets.ISO_8859_1)
        if (sig != "GIF87a" && sig != "GIF89a") throw NotAGif()
        var i = 13
        if (b.size < i) throw NotAGif()
        val packed = b[10].toInt() and 0xff
        if (packed and 0x80 != 0) i += 3 * (1 shl ((packed and 7) + 1)) // global colour table
        if (b.size < i) throw NotAGif()
        val out = ByteArrayOutputStream(b.size)
        out.write(b, 0, i)

        // Sub-blocks from `at`: the index after the 0 terminator, and the first `keep` data bytes.
        fun blocks(start: Int, keep: Int = 0): Pair<Int, ByteArray> {
            var at = start
            val data = ByteArrayOutputStream(keep)
            while (true) {
                if (at >= b.size) throw NotAGif()
                val n = b[at++].toInt() and 0xff
                if (n == 0) return at to data.toByteArray()
                if (at + n > b.size) throw NotAGif()
                val take = minOf(n, keep - data.size())
                if (take > 0) data.write(b, at, take)
                at += n
            }
        }

        // A graphic control waits for what it controls: a frame keeps it, a dropped text block takes it along.
        var control: IntRange? = null
        var looped = false
        var frames = 0
        while (true) {
            if (i >= b.size) throw NotAGif()
            val kind = b[i].toInt() and 0xff
            if (kind == 0x3b) { out.write(0x3b); break }
            if (kind == 0x2c) {
                if (i + 10 > b.size) throw NotAGif()
                var at = i + 10
                val local = b[i + 9].toInt() and 0xff
                if (local and 0x80 != 0) at += 3 * (1 shl ((local and 7) + 1)) // local colour table
                at += 1 // LZW minimum code size
                if (at > b.size) throw NotAGif()
                val (end, _) = blocks(at)
                control?.let { out.write(b, it.first, it.last - it.first + 1) }
                control = null
                out.write(b, i, end - i)
                frames++
                i = end
                continue
            }
            if (kind != 0x21 || i + 2 > b.size) throw NotAGif()
            val label = b[i + 1].toInt() and 0xff
            val (end, data) = blocks(i + 2, if (label == 0xff) 14 else 0)
            when {
                label == 0xf9 -> {
                    if (end - i != 8 || b[i + 2].toInt() != 4) throw NotAGif()
                    control = i until end
                }
                label == 0x01 -> control = null // plain text: dropped, and its timing with it
                label == 0xff && !looped && data.size >= 14 -> {
                    val id = String(data, 0, 11, Charsets.ISO_8859_1)
                    // The loop block: its first sub-block is 3 bytes, [1, loops lo, loops hi].
                    if ((id == "NETSCAPE2.0" || id == "ANIMEXTS1.0") && (b[i + 2].toInt() and 0xff) == 11 &&
                        (b[i + 14].toInt() and 0xff) == 3 && data[11].toInt() == 1
                    ) {
                        out.write(byteArrayOf(0x21, 0xff.toByte(), 11))
                        out.write("NETSCAPE2.0".toByteArray(Charsets.ISO_8859_1))
                        out.write(byteArrayOf(3, 1, data[12], data[13], 0))
                        looped = true
                    }
                }
            }
            // 0xfe comments, every other application block (XMP, ICC, Photoshop, …) and unknown labels: left behind.
            i = end
        }
        if (frames == 0) throw NotAGif() // a GIF with no frame is no picture
        return out.toByteArray()
    }
}

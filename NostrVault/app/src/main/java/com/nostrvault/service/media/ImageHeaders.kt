package com.nostrvault.service.media

/**
 * What [ImageCompressor] reads from a picture's first bytes, before deciding
 * whether to re-encode it. Pure byte work, so the rules can be tested on the JVM.
 */
internal object ImageHeaders {
    private val HEIC_TYPES = setOf("image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence")
    private val SEQUENCE_TYPES = setOf("image/heic-sequence", "image/heif-sequence")

    /** The type without parameters, lower case: `image/HEIC; x=y` is `image/heic`. */
    fun bareType(mimeType: String): String = mimeType.lowercase().substringBefore(';').trim()

    fun isHeic(mimeType: String): Boolean = bareType(mimeType) in HEIC_TYPES

    /** A HEIC/HEIF picture sequence (a burst or a moving picture): left as it is, like a GIF. */
    fun isHeicSequence(mimeType: String): Boolean = bareType(mimeType) in SEQUENCE_TYPES

    fun isGif(head: ByteArray): Boolean =
        head.size >= 4 && head[0] == 'G'.code.toByte() && head[1] == 'I'.code.toByte() &&
            head[2] == 'F'.code.toByte() && head[3] == '8'.code.toByte()

    /**
     * An animated WebP: RIFF....WEBPVP8X with the animation flag (bit 1 of
     * the byte after the chunk size). A still WebP is re-encoded; this one isn't.
     */
    fun isAnimatedWebp(head: ByteArray): Boolean {
        if (head.size < 21) return false
        fun at(i: Int, s: String) = s.indices.all { head[i + it] == s[it].code.toByte() }
        return at(0, "RIFF") && at(8, "WEBP") && at(12, "VP8X") && (head[20].toInt() and 0x02) != 0
    }

    /**
     * Whether a PNG can be see-through: colour type 4 or 6 (it has an alpha
     * channel) or a tRNS chunk before the image data. [head] is the file's
     * start; null when it isn't a PNG.
     */
    fun pngHasAlpha(head: ByteArray): Boolean? {
        val signature = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 0x0D, 0x0A, 0x1A, 0x0A)
        if (head.size < 26 || signature.indices.any { head[it] != signature[it] }) return null
        val colourType = head[25].toInt() and 0xFF
        if (colourType == 4 || colourType == 6) return true
        // Chunks: 4-byte length, 4-byte type, data, 4-byte CRC.
        var i = 8
        while (i + 8 <= head.size) {
            val length = ((head[i].toLong() and 0xFF) shl 24) or ((head[i + 1].toLong() and 0xFF) shl 16) or
                ((head[i + 2].toLong() and 0xFF) shl 8) or (head[i + 3].toLong() and 0xFF)
            val type = String(head, i + 4, 4, Charsets.ISO_8859_1)
            if (type == "tRNS") return true
            if (type == "IDAT" || type == "IEND") return false
            val next = i + 12L + length
            if (next > head.size) break
            i = next.toInt()
        }
        // The chunks before the image data ran past what was read: say it can
        // be see-through, so it stays a PNG rather than losing its alpha.
        return true
    }

    /**
     * [jpeg] with every metadata segment left out: EXIF (camera, serial,
     * time, location), XMP, Photoshop/IPTC, comments and the other APPn
     * blocks. Kept: JFIF (APP0), the colour profile (APP2 `ICC_PROFILE`) and
     * Adobe's colour flag (APP14), which change how it looks. Anything after
     * the picture's end (a second picture, a gain map) is left out too.
     * Null when the segments can't be walked; the caller re-encodes instead.
     *
     * Only for a picture that needs no turning: the EXIF it drops is where
     * the turn is kept.
     */
    fun jpegWithoutMetadata(jpeg: ByteArray): ByteArray? {
        fun u8(i: Int) = jpeg[i].toInt() and 0xFF
        if (jpeg.size < 4 || u8(0) != 0xFF || u8(1) != 0xD8) return null
        val out = java.io.ByteArrayOutputStream(jpeg.size)
        out.write(jpeg, 0, 2)
        var i = 2
        while (true) {
            if (i + 4 > jpeg.size || u8(i) != 0xFF) return null
            val marker = u8(i + 1)
            if (marker == 0xDA) break
            val length = (u8(i + 2) shl 8) or u8(i + 3)
            val end = i + 2 + length
            if (length < 2 || end > jpeg.size) return null
            if (keepsSegment(jpeg, marker, i + 4, end)) out.write(jpeg, i, end - i)
            i = end
        }
        // From the first scan to the end-of-image marker. 0xFF in coded data
        // is always followed by 0x00 or a restart marker, so the first FFD9 is the end.
        var j = i + 2
        while (j + 1 < jpeg.size && !(u8(j) == 0xFF && u8(j + 1) == 0xD9)) j++
        if (j + 1 >= jpeg.size) return null
        out.write(jpeg, i, j + 2 - i)
        return out.toByteArray()
    }

    private val ICC = "ICC_PROFILE\u0000".toByteArray(Charsets.ISO_8859_1)

    private fun keepsSegment(jpeg: ByteArray, marker: Int, dataStart: Int, end: Int): Boolean = when (marker) {
        0xE0, 0xEE -> true
        0xE2 -> dataStart + ICC.size <= end && ICC.indices.all { jpeg[dataStart + it] == ICC[it] }
        0xFE -> false
        in 0xE1..0xEF -> false
        else -> true
    }
}

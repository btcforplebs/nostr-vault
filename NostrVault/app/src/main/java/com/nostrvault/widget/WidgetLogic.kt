package com.nostrvault.widget

import kotlinx.serialization.Serializable
import kotlin.math.max
import kotlin.math.min

/**
 * Widget arithmetic, kept free of Android and Glance types so JVM unit tests
 * can reach it. Mirrors HavenApp/HavenApp/Shared/NVWidgetLogic.swift.
 */

/**
 * What a Mosaic tile is. Coarser than the gallery's own types on purpose: the
 * widget filters by the same four buckets as the Media tab's chips.
 */
@Serializable
enum class MediaKind { IMAGE, VIDEO, GIF, OTHER;

    companion object {
        /**
         * Sniffs the first bytes of a blob. Blossom files are bare hashes, so
         * the name says nothing about the type.
         */
        fun fromHeader(header: ByteArray): MediaKind? {
            fun at(i: Int, c: Char) = header.size > i && header[i] == c.code.toByte()
            fun ascii(offset: Int, s: String) = s.indices.all { at(offset + it, s[it]) }
            if (header.size < 4) return null
            return when {
                ascii(0, "GIF8") -> GIF
                header[0] == 0xFF.toByte() && header[1] == 0xD8.toByte() && header[2] == 0xFF.toByte() -> IMAGE
                header[0] == 0x89.toByte() && ascii(1, "PNG") -> IMAGE
                ascii(0, "RIFF") && ascii(8, "WEBP") -> IMAGE
                // ISO-BMFF: HEIC/AVIF stills share the container with MP4/MOV,
                // so the brand decides.
                ascii(4, "ftyp") -> {
                    val brand = (8 until 12).map { header.getOrNull(it)?.toInt()?.toChar() ?: ' ' }
                        .joinToString("")
                    if (brand in setOf("heic", "heix", "mif1", "msf1", "avif", "heim", "heis")) IMAGE else VIDEO
                }
                header[0] == 0x1A.toByte() && header[1] == 0x45.toByte() -> VIDEO
                else -> OTHER
            }
        }
    }
}

/** The chips across the top of Mosaic, mirroring the Media tab. */
enum class MosaicFilter(val label: String) {
    ALL("All"), PHOTO("Photos"), VIDEO("Video"), GIF("GIF");

    /**
     * A tile nothing sniffed is shown under All and hidden by every narrower
     * chip: guessing would put videos under Photos.
     */
    fun accepts(kind: MediaKind?): Boolean = when (this) {
        ALL -> true
        PHOTO -> kind == MediaKind.IMAGE
        VIDEO -> kind == MediaKind.VIDEO
        GIF -> kind == MediaKind.GIF
    }

    companion object {
        fun fromKey(key: String?): MosaicFilter = entries.firstOrNull { it.name == key } ?: ALL
    }
}

/** How a Mosaic grid fills the space the launcher gave it. */
object MosaicGrid {
    /** The most tiles the publisher hands over (iOS NVWidgetBridge.maxTiles). */
    const val MAX_TILES = 18

    data class Plan(val columns: Int, val rows: Int, val tileDp: Float) {
        val capacity: Int get() = columns * rows
    }

    /**
     * Columns come from the width so a tile stays big enough to read as a
     * picture rather than a swatch (iOS: 2 across a small widget, 6 across an
     * extra-large one); rows are however many whole squares the height holds.
     */
    fun plan(widthDp: Float, heightDp: Float, gapDp: Float, minTileDp: Float = 64f): Plan {
        if (widthDp <= 0f || heightDp <= 0f) return Plan(columns = 2, rows = 1, tileDp = minTileDp)
        val columns = ((widthDp + gapDp) / (minTileDp + gapDp)).toInt().coerceIn(2, 6)
        val tile = (widthDp - gapDp * (columns - 1)) / columns
        val rows = max(1, ((heightDp + gapDp) / (tile + gapDp)).toInt())
        val cappedRows = min(rows, max(1, MAX_TILES / columns))
        return Plan(columns, cappedRows, tile)
    }

    /**
     * Featured layout: one hero, then a strip of small tiles under it when
     * the widget is tall enough to spare one. Narrow widgets get the hero only
     * (iOS draws a single tile on small).
     */
    fun featuredStripCount(widthDp: Float, heightDp: Float, stripDp: Float, gapDp: Float): Int {
        if (heightDp < stripDp * 3 || widthDp < 150f) return 0
        return ((widthDp + gapDp) / (stripDp + gapDp)).toInt().coerceIn(0, 8)
    }
}

/** BitmapFactory's inSampleSize for decoding at about [maxPixel] on the long edge. */
fun sampleSizeFor(width: Int, height: Int, maxPixel: Int): Int {
    if (width <= 0 || height <= 0 || maxPixel <= 0) return 1
    var sample = 1
    // Power of two, and never so far that the result drops below maxPixel.
    while (max(width, height) / (sample * 2) >= maxPixel) sample *= 2
    return sample
}

/** A stable hue (0..359) for a tile or avatar with no picture, keyed to its id. */
fun seededHue(seed: String): Float = ((seed.hashCode() % 360 + 360) % 360).toFloat()

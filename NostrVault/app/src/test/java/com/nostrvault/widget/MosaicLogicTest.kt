package com.nostrvault.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MosaicLogicTest {

    private fun bytes(vararg parts: Any): ByteArray = parts.flatMap { p ->
        when (p) {
            is String -> p.toByteArray(Charsets.ISO_8859_1).toList()
            is Int -> listOf(p.toByte())
            else -> error("bad part")
        }
    }.toByteArray()

    @Test
    fun sniffsEachKindFromItsMagicBytes() {
        assertEquals(MediaKind.GIF, MediaKind.fromHeader(bytes("GIF89a", 0, 0, 0, 0, 0, 0)))
        assertEquals(MediaKind.IMAGE, MediaKind.fromHeader(bytes(0xFF, 0xD8, 0xFF, 0xE0)))
        assertEquals(MediaKind.IMAGE, MediaKind.fromHeader(bytes(0x89, "PNG", 0x0D, 0x0A)))
        assertEquals(MediaKind.IMAGE, MediaKind.fromHeader(bytes("RIFF", 0, 0, 0, 0, "WEBP")))
        assertEquals(MediaKind.VIDEO, MediaKind.fromHeader(bytes(0, 0, 0, 0x18, "ftypisom")))
        assertEquals(MediaKind.VIDEO, MediaKind.fromHeader(bytes(0x1A, 0x45, 0xDF, 0xA3)))
        assertEquals(MediaKind.OTHER, MediaKind.fromHeader(bytes("ID3", 4)))
    }

    @Test
    fun heicShareTheVideoContainerButAreStills() {
        assertEquals(MediaKind.IMAGE, MediaKind.fromHeader(bytes(0, 0, 0, 0x18, "ftypheic")))
        assertEquals(MediaKind.IMAGE, MediaKind.fromHeader(bytes(0, 0, 0, 0x18, "ftypavif")))
    }

    @Test
    fun tooShortToSniffIsUnknownNotOther() {
        assertNull(MediaKind.fromHeader(bytes(0xFF, 0xD8)))
    }

    @Test
    fun unsniffedTilesOnlyShowUnderAll() {
        assertTrue(MosaicFilter.ALL.accepts(null))
        MosaicFilter.entries.filter { it != MosaicFilter.ALL }.forEach { assertFalse(it.accepts(null)) }
        assertTrue(MosaicFilter.PHOTO.accepts(MediaKind.IMAGE))
        assertFalse(MosaicFilter.PHOTO.accepts(MediaKind.GIF))
        assertTrue(MosaicFilter.GIF.accepts(MediaKind.GIF))
        assertTrue(MosaicFilter.VIDEO.accepts(MediaKind.VIDEO))
    }

    @Test
    fun unknownFilterKeyFallsBackToAll() {
        assertEquals(MosaicFilter.ALL, MosaicFilter.fromKey(null))
        assertEquals(MosaicFilter.ALL, MosaicFilter.fromKey("bogus"))
        assertEquals(MosaicFilter.GIF, MosaicFilter.fromKey("GIF"))
    }

    @Test
    fun smallWidgetIsATwoByTwo() {
        val plan = MosaicGrid.plan(widthDp = 140f, heightDp = 140f, gapDp = 4f)
        assertEquals(2, plan.columns)
        assertEquals(2, plan.rows)
        assertEquals(68f, plan.tileDp, 0.01f)
    }

    @Test
    fun wideShortWidgetUsesMoreColumnsNotTinyRows() {
        val plan = MosaicGrid.plan(widthDp = 330f, heightDp = 120f, gapDp = 4f)
        assertEquals(4, plan.columns)
        assertEquals(1, plan.rows)
    }

    @Test
    fun gridNeverOverflowsTheHeight() {
        for (h in listOf(80f, 150f, 260f, 400f, 700f)) {
            val p = MosaicGrid.plan(widthDp = 300f, heightDp = h, gapDp = 4f)
            val used = p.rows * p.tileDp + (p.rows - 1) * 4f
            assertTrue("height $h used $used", p.rows == 1 || used <= h + 0.01f)
        }
    }

    @Test
    fun gridNeverAsksForMoreTilesThanArePublished() {
        val p = MosaicGrid.plan(widthDp = 700f, heightDp = 2000f, gapDp = 4f)
        assertEquals(6, p.columns)
        assertTrue(p.capacity <= MosaicGrid.MAX_TILES)
    }

    @Test
    fun sampleSizeIsAPowerOfTwoThatKeepsTheTargetSize() {
        assertEquals(1, sampleSizeFor(200, 100, 240))
        assertEquals(16, sampleSizeFor(4000, 3000, 240))
        // Never sampled below the target.
        val s = sampleSizeFor(4032, 3024, 240)
        assertTrue(4032 / s >= 240)
        assertTrue(4032 / (s * 2) < 240)
        assertEquals(1, sampleSizeFor(0, 0, 240))
    }
}

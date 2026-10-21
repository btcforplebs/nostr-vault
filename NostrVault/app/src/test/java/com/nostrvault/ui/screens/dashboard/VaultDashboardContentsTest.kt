package com.nostrvault.ui.screens.dashboard

import com.nostrvault.service.StatsService
import com.nostrvault.ui.screens.dashboard.VaultDashboardContents.MediaType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultDashboardContentsTest {
    private val c = VaultDashboardContents

    @Test fun `every kind a row names is counted`() {
        val named = c.groups.flatMap { it.kinds } + c.otherKinds
        assertEquals(named.size, named.toSet().size)
        assertEquals(named.toSet(), StatsService.COUNTED_KINDS.toSet())
    }

    @Test fun `groups sum their kinds and yours`() {
        val rows = c.groupRows(
            total = 1_300,
            byKind = mapOf(1 to 1_100, 6 to 80, 1111 to 50, 1068 to 4, 7 to 60),
            yoursByKind = mapOf(1 to 900, 6 to 80),
        )
        val notes = rows.first { it.group.id == "notes" }
        assertEquals(1_234, notes.count)
        assertEquals(980, notes.yours)
        assertEquals(listOf(1, 6, 1111, 1068), notes.kinds.map { it.kind })
        assertEquals(0, rows.first { it.group.id == "reactions" }.yours)
    }

    @Test fun `zaps never claim to be yours`() {
        val rows = c.groupRows(total = 4, byKind = mapOf(9735 to 4), yoursByKind = mapOf(9735 to 4))
        assertNull(rows.first { it.group.id == "zaps" }.yours)
    }

    @Test fun `no yours when not counted for this account`() {
        val rows = c.groupRows(total = 5, byKind = mapOf(1 to 5), yoursByKind = null)
        assertNull(rows.first { it.group.id == "notes" }.yours)
    }

    @Test fun `messages never claim to be yours`() {
        val rows = c.groupRows(total = 8, byKind = mapOf(4 to 3, 1059 to 5), yoursByKind = mapOf(4 to 3))
        val messages = rows.single { it.group.id == "messages" }
        assertEquals(8, messages.count)
        assertNull(messages.yours)
        assertFalse(4 in c.yourKinds || 1059 in c.yourKinds)
    }

    @Test fun `other is the total less the named groups`() {
        val rows = c.groupRows(total = 700, byKind = mapOf(1 to 100, 5 to 400, 30078 to 50), yoursByKind = emptyMap())
        val other = rows.last()
        assertEquals("Other", other.group.title)
        assertEquals(600, other.count)
        assertEquals(listOf(5 to 400, null to 150, 30078 to 50), other.kinds.map { it.kind to it.count })
        assertEquals("Kinds not listed", other.kinds[1].title)
        assertEquals("Deletions", other.kinds[0].title)
    }

    @Test fun `empty groups are left out`() {
        val rows = c.groupRows(total = 3, byKind = mapOf(9802 to 3), yoursByKind = emptyMap())
        assertEquals(listOf("highlights"), rows.map { it.group.id })
    }

    @Test fun `media type comes from the bytes`() {
        fun b(vararg x: Int) = ByteArray(x.size) { x[it].toByte() }
        fun s(t: String) = t.toByteArray(Charsets.US_ASCII)
        assertEquals(MediaType.IMAGE, c.mediaType(b(0xFF, 0xD8, 0xFF, 0xE0)))
        assertEquals(MediaType.IMAGE, c.mediaType(b(0x89, 0x50, 0x4E, 0x47)))
        assertEquals(MediaType.IMAGE, c.mediaType(s("RIFF\u0000\u0000\u0000\u0000WEBP")))
        assertEquals(MediaType.IMAGE, c.mediaType(s("\u0000\u0000\u0000\u0018ftypheic")))
        assertEquals(MediaType.VIDEO, c.mediaType(s("\u0000\u0000\u0000\u0018ftypisom")))
        assertEquals(MediaType.AUDIO, c.mediaType(s("\u0000\u0000\u0000\u0018ftypM4A ")))
        assertEquals(MediaType.VIDEO, c.mediaType(b(0x1A, 0x45, 0xDF, 0xA3)))
        assertEquals(MediaType.AUDIO, c.mediaType(s("ID3\u0004")))
        assertEquals(MediaType.AUDIO, c.mediaType(s("OggS")))
        assertEquals(MediaType.AUDIO, c.mediaType(s("RIFF\u0000\u0000\u0000\u0000WAVE")))
        assertEquals(MediaType.OTHER, c.mediaType(s("%PDF-1.7")))
        assertEquals(MediaType.OTHER, c.mediaType(ByteArray(0)))
    }

    @Test fun `only blob-named files are media`() {
        assertTrue(c.isListedBlob("a".repeat(64)))
        assertFalse(c.isListedBlob("A".repeat(64)))
        assertFalse(c.isListedBlob("LOCK"))
    }
}

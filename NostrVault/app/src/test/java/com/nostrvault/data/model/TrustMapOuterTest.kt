package com.nostrvault.data.model

import com.nostrvault.fips.DeviceRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The globe's outer rings from the desktop Vault's rank. iOS `TrustMapOuterTests.swift`. */
class TrustMapOuterTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a')

    private fun row(c: Char, score: Int, hop: Int, via: Char = 'b') = "[\"${pk(c)}\",$score,$hop,\"${pk(via)}\"]"

    /**
     * people: b hop 1, d hop 3 at 70 (feed rows: the globe must not read them).
     * globe: c hop 2 (a link), e hop 3 at 80, f hop 3 at 20 (under any bar), 0 hop 4 at 12, 1 hop 5 at 3.
     */
    private fun copy(globe: String? = listOf(row('c', 40, 2), row('e', 80, 3, 'c'), row('f', 20, 3, 'c'),
        row('0', 12, 4, 'e'), row('1', 3, 5, '0')).joinToString(",")): TrustRankCopy {
        val people = "[\"${pk('b')}\",100,1],[\"${pk('d')}\",70,3]"
        val g = globe?.let { ",\"globe\":[$it]" } ?: ""
        val text = "{\"account\":\"$me\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":5," +
            "\"people\":[$people],\"viewBar\":55,\"floor\":45$g}"
        return TrustRankCopy.parse(text, me)!!
    }

    @Test fun `ranked rings come from the globe list, hops 3 to 5, no bar, in its order`() {
        val outer = TrustMapOuter.make(copy(), desktopPaired = true)
        assertEquals(TrustMapOuter.Source.RANKED, outer.source)
        assertFalse(outer.isFaint)
        assertEquals("hop-2 links are not a ring", listOf(3, 4, 5), outer.rings.map { it.hop })
        assertEquals("f at 20 is shown; d is only a feed row", listOf(pk('e'), pk('f')), outer.rings[0].top)
        assertEquals(listOf(pk('1')), outer.rings[2].top)
        assertEquals("3 hops · top 2", TrustMapOuter.chipText(outer.rings[0]))
        assertEquals("The 1 best-ranked person in this ring.", TrustMapOuter.countText(outer.rings[2]))
    }

    @Test fun `a ring shows its first 300 rows, never its chain links after them`() {
        val hex = "0123456789abcdef"
        fun key(i: Int) = (0 until 64).map { hex[(i shr ((it % 4) * 4)) and 15] }.joinToString("")
        val rows = (0 until TrustRankCopy.GLOBE_PER_RING + 5).joinToString(",") { "[\"${key(it + 1)}\",${50 - it / 10},3,\"${pk('c')}\"]" }
        val outer = TrustMapOuter.make(copy(globe = row('c', 40, 2) + "," + rows), desktopPaired = true)
        assertEquals(TrustRankCopy.GLOBE_PER_RING, outer.rings.single().count)
        assertEquals(key(1), outer.rings.single().top.first())
        assertEquals("3 hops · top 300", TrustMapOuter.chipText(outer.rings.single()))
    }

    @Test fun `a short ring never counts its chain links at 0 as top`() {
        val outer = TrustMapOuter.make(copy(globe = listOf(row('c', 40, 2), row('e', 80, 3, 'c'),
            row('0', 12, 4, 'e'), row('2', 0, 4, 'e'), row('1', 3, 5, '2')).joinToString(",")), desktopPaired = true)
        val ring4 = outer.rings.single { it.hop == 4 }
        assertEquals(listOf(pk('0')), ring4.top)
        assertEquals("4 hops · top 1", TrustMapOuter.chipText(ring4))
    }

    @Test fun `fade per hop, 3 full, 4 about 60 percent, 5 about 35`() {
        assertEquals(1f, TrustMapOuter.fade(3), 0f)
        assertEquals(0.6f, TrustMapOuter.fade(4), 0f)
        assertEquals(0.35f, TrustMapOuter.fade(5), 0f)
    }

    @Test fun `a copy from an engine before the globe list has no rings to draw`() {
        val outer = TrustMapOuter.make(copy(globe = null), desktopPaired = true)
        assertEquals(TrustMapOuter.Source.RANKED, outer.source)
        assertTrue(outer.rings.isEmpty())
    }

    @Test fun `a blocked person is left out`() {
        val outer = TrustMapOuter.make(copy(), desktopPaired = true, hidden = setOf(pk('e')))
        assertEquals(listOf(pk('f')), outer.rings[0].top)
        assertEquals(1, outer.rings[0].count)
    }

    @Test fun `a rank copy counts even with no desktop in the device list`() {
        assertEquals(TrustMapOuter.Source.RANKED, TrustMapOuter.make(copy(), desktopPaired = false).source)
    }

    @Test fun `no rank draws faint rings and invites only without a desktop Vault`() {
        val invite = TrustMapOuter.make(null, desktopPaired = false)
        assertEquals(TrustMapOuter.Source.INVITE, invite.source)
        assertTrue(invite.isFaint)
        assertEquals(listOf(3, 4, 5), invite.rings.map { it.hop })
        assertTrue(invite.rings.all { it.count == 0 && it.top.isEmpty() })
        assertEquals(TrustMapOuter.Source.WAITING, TrustMapOuter.make(null, desktopPaired = true).source)
    }

    @Test fun `only a Mac counts as a desktop Vault`() {
        assertFalse(TrustMapOuter.desktopPaired(listOf(DeviceRole.PHONE, DeviceRole.HOME_VAULT, DeviceRole.BROWSER)))
        assertTrue(TrustMapOuter.desktopPaired(listOf(DeviceRole.PHONE, DeviceRole.MAC)))
    }

    @Test fun `the words never say Haven`() {
        for (text in listOf(TrustMapOuter.FOUND_LABEL, TrustMapOuter.WAITING_LABEL, TrustMapOuter.PAIR_LINE)) {
            assertFalse(text, text.contains("haven", ignoreCase = true))
        }
    }
}

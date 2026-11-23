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

    /** b hop 1, c hop 2, d hop 3 at 70, e hop 3 at 80, f hop 3 at 50, 0 hop 4 at 60, 1 hop 6 at 90. */
    private fun copy(): TrustRankCopy {
        val rows = listOf(Triple('b', 100, 1), Triple('c', 80, 2), Triple('d', 70, 3), Triple('e', 80, 3),
            Triple('f', 50, 3), Triple('0', 60, 4), Triple('1', 90, 6))
            .joinToString(",") { "[\"${pk(it.first)}\",${it.second},${it.third}]" }
        val text = "{\"account\":\"$me\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6," +
            "\"people\":[$rows],\"viewBar\":55,\"floor\":45}"
        return TrustRankCopy.parse(text, me)!!
    }

    @Test fun `ranked rings hold only people three or more hops out over the bar, best first`() {
        val outer = TrustMapOuter.make(copy(), 55.0, desktopPaired = true)
        assertEquals(TrustMapOuter.Source.RANKED, outer.source)
        assertFalse(outer.isFaint)
        assertEquals("no ring 5: nobody is there", listOf(3, 4, 6), outer.rings.map { it.hop })
        assertEquals("f is under the bar", 2, outer.rings[0].count)
        assertEquals(listOf(pk('e'), pk('d')), outer.rings[0].top)
        assertEquals(listOf(pk('1')), outer.rings[2].top)
        assertEquals("3 hops · 2", TrustMapOuter.chipText(outer.rings[0]))
        assertEquals("1 person at score 55 and up.", TrustMapOuter.countText(outer.rings[2], 55.0))
    }

    @Test fun `a blocked person is left out`() {
        val outer = TrustMapOuter.make(copy(), 55.0, desktopPaired = true, hidden = setOf(pk('e')))
        assertEquals(listOf(pk('d')), outer.rings[0].top)
        assertEquals(1, outer.rings[0].count)
    }

    @Test fun `a rank copy counts even with no desktop in the device list`() {
        assertEquals(TrustMapOuter.Source.RANKED, TrustMapOuter.make(copy(), 55.0, desktopPaired = false).source)
    }

    @Test fun `no rank draws faint rings and invites only without a desktop Vault`() {
        val invite = TrustMapOuter.make(null, null, desktopPaired = false)
        assertEquals(TrustMapOuter.Source.INVITE, invite.source)
        assertTrue(invite.isFaint)
        assertEquals(listOf(3, 4, 5), invite.rings.map { it.hop })
        assertTrue(invite.rings.all { it.count == 0 && it.top.isEmpty() })
        assertEquals(TrustMapOuter.Source.WAITING, TrustMapOuter.make(null, null, desktopPaired = true).source)
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

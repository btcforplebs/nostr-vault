package com.nostrvault.ui.screens.dashboard

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.MyDevice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The dashboard's device words (Tao, nv-android acefaeee): two "Mac" rows, and status errors with their own words. */
class DashboardDeviceWordsTest {
    private fun device(npub: String, name: String, role: DeviceRole = DeviceRole.MAC, inReach: Boolean = true) =
        MyDevice(npub, role, name, inReach, 0)

    @Test fun `two rows with the same name get the end of their npub`() {
        val a = device("npub1aaaax2we", "Mac")
        val b = device("npub1bbbbf4p2", "mac")
        val box = device("npub1cccc539a", "Nostr Vault box")
        val t = DashboardDeviceWords.titles(listOf(a, b, box))
        assertEquals("Mac · x2we", t[a.npub])
        assertEquals("mac · f4p2", t[b.npub])
        assertEquals("a unique name stays as it is", "Nostr Vault box", t[box.npub])
        assertNotEquals(t[a.npub], t[b.npub])
    }

    @Test fun `unnamed devices of one role are told apart too`() {
        val a = device("npub1aaaa1111", "")
        val b = device("npub1bbbb2222", " ")
        val t = DashboardDeviceWords.titles(listOf(a, b))
        assertEquals("${DeviceRole.MAC.label} · 1111", t[a.npub])
        assertEquals("${DeviceRole.MAC.label} · 2222", t[b.npub])
    }

    @Test fun `the devices count says mesh, not reach`() {
        assertNull(DashboardDeviceWords.meshCount(emptyList()))
        assertEquals(
            "2 of 3 on the mesh",
            DashboardDeviceWords.meshCount(listOf(device("a", "A"), device("b", "B"), device("c", "C", inReach = false))),
        )
    }

    @Test fun `each status error has its own words, and none says out of reach`() {
        assertNull(DashboardDeviceWords.statusReach(null))
        val codes = listOf("not_paired", "not_found", "auth_refused", "bad_answer", "unreachable", "cancelled")
        val words = codes.map { DashboardDeviceWords.statusReach(it)!! }
        assertEquals("auth_refused and bad_answer differ from unreachable", 5, words.toSet().size)
        assertEquals(words[4], words[5])
        words.forEach { assertNotEquals(-1, it.length); assert(!it.contains("reach")) { it } }
    }
}

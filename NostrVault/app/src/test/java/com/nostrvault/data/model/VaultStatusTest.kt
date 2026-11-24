package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.util.Locale

/** The desktop Vault status read and its words: the same as iOS `VaultStatusTests` and `DesktopVaultPickTests`. */
class VaultStatusTest {
    private val me = "a".repeat(64)

    @Before fun locale() = Locale.setDefault(Locale.US)

    private fun buckets(at: Map<Int, Int>) = (0..100).joinToString(",", "[", "]") { (at[it] ?: 0).toString() }

    @Test fun runningPassSaysItsRingAndLists() {
        val s = VaultStatus.decode(
            """{"version":1,"at":1000,"state":"running","accounts":[{"account":"$me","running":true,"ring":3,"ringDone":412,
            "ringTotal":1980,"listsRead":37,"finishedAt":0,"distantAtBar":0,"handoffs":[]}]}""",
        )!!
        assertEquals("Ranking your web", VaultStatusText.headline(s))
        val a = s.account(me)!!
        assertEquals("Ring 3 · 412 of 1,980 lists · 37 read this run", VaultStatusText.progress(a))
        assertEquals("No ranking yet", VaultStatusText.finished(a, 1000))
        assertNull(VaultStatusText.pausedHint(s))
    }

    @Test fun pausedSaysWhyAndKeepsItsPlace() {
        val s = VaultStatus.decode(
            """{"version":1,"at":1000,"state":"paused","pausedWhy":"app","accounts":[{"account":"$me","running":false,"ring":2,
            "ringDone":50,"cut":true,"finishedAt":0,"distantAtBar":0,"handoffs":[]}]}""",
        )!!
        assertEquals("Paused while the window is open", VaultStatusText.headline(s))
        assertNotNull(VaultStatusText.pausedHint(s))
        assertEquals("Ring 2 · 50 lists read · waiting to go on", VaultStatusText.progress(s.accounts[0]))
        val busy = s.copy(pausedWhy = "busy")
        assertEquals("Paused while an import or copy runs", VaultStatusText.headline(busy))
        assertNull(VaultStatusText.pausedHint(busy))
    }

    @Test fun finishedPassCountsDistantConnectionsAtTheBar() {
        val b = "b".repeat(64)
        val s = VaultStatus.decode(
            """{"version":1,"at":10000,"state":"idle","accounts":[{"account":"$me","running":false,"finishedAt":2800,
            "result":{"builtAt":2800,"people":78855,"maxHop":5,"rings":[1,2],"distantByShown":${buckets(mapOf(54 to 5, 55 to 3, 80 to 2))},"viewBar":55},
            "distantAtBar":5,"distantFetchAt":9280,"distantFetchPeople":500,"distantFetchNew":34,"newField":1,
            "handoffs":[{"device":"$b","role":"phone","tookAt":6400,"builtAt":2800,"checkedAt":9900},
            {"device":"${"c".repeat(64)}","checkedAt":9900}]}]}""",
        )!!
        val a = s.account("unknown")!!
        assertEquals("Idle", VaultStatusText.headline(s))
        assertNull(VaultStatusText.progress(a))
        assertEquals("Finished 2 h ago · 78,855 people ranked", VaultStatusText.finished(a, 10000))
        assertEquals("5 distant connections at your bar (55)", VaultStatusText.distant(a, null))
        assertEquals("10 distant connections at your bar (54)", VaultStatusText.distant(a, 54.0))
        assertEquals("0 distant connections at your bar (81)", VaultStatusText.distant(a, 81.0))
        assertEquals("Distant posts fetched 12 min ago · 34 new from 500 people", VaultStatusText.distantFetch(a, 10000))
        assertEquals("Took it 1 h ago", VaultStatusText.handoff(a.handoffs[0], 10000))
        assertEquals("Hasn't taken the ranking yet", VaultStatusText.handoff(a.handoffs[1], 10000))
        val roles = { r: String -> if (r == "phone") "Phone" else null }
        assertEquals("This device", DesktopVaultPick.handoffName(a.handoffs[0], emptyMap(), b.uppercase(), roles))
        assertEquals("Logen's Moto", DesktopVaultPick.handoffName(a.handoffs[0], mapOf(b to "Logen's Moto"), null, roles))
        assertEquals("Phone", DesktopVaultPick.handoffName(a.handoffs[0], emptyMap(), null, roles))
        assertEquals("A paired device", DesktopVaultPick.handoffName(a.handoffs[1], emptyMap(), null, roles))
        assertEquals("Phone", DesktopVaultPick.handoffName(a.handoffs[0], mapOf(b to "  "), null, roles))
        val named = a.handoffs[0].copy(name = " LogePhone ")
        assertEquals("LogePhone", DesktopVaultPick.handoffName(named, mapOf(b to "Logen's Moto"), b, roles))
        assertEquals("12 mini", VaultStatus.decode(
            """{"version":1,"at":1,"state":"idle","accounts":[{"account":"$me","handoffs":[{"device":"$b","name":"12 mini","checkedAt":1}]}]}""",
        )!!.accounts[0].handoffs[0].name)
    }

    @Test fun offAgoAndTheEngineAnswer() {
        val s = VaultStatus.decode("""{"version":1,"at":1,"state":"off","accounts":[]}""")!!
        assertEquals("Trust ranking is off here", VaultStatusText.headline(s))
        assertNull(s.account(me))
        assertEquals("just now", VaultStatusText.ago(199_990, 200_000))
        assertEquals("1 day ago", VaultStatusText.ago(200_000 - 86_400, 200_000))
        assertEquals("just now", VaultStatusText.ago(300_000, 200_000))
        assertNull(VaultStatus.decode("not json"))
        assertNull(VaultStatus.decode("""{"version":0,"state":""}"""))
        val (ok, err) = VaultStatus.answer("""{"status":{"version":1,"at":5,"state":"idle","accounts":[]}}""")
        assertEquals("idle", ok!!.first.state)
        assertNull(err)
        assertEquals(null to "auth_refused", VaultStatus.answer("""{"error":"auth_refused"}"""))
        assertEquals(null to null, VaultStatus.answer("nope"))
        assertEquals("Updated 1 min ago", DesktopVaultPick.updated(940, 1000))
    }

    @Test fun theLatestCaughtUpDesktopIsPicked() {
        val desktops = listOf("macA", "macB")
        assertEquals("macB", DesktopVaultPick.desktop(desktops, { it }, mapOf("macA" to 100L, "macB" to 200L)))
        assertEquals("macA", DesktopVaultPick.desktop(desktops, { it }, mapOf("macA" to 300L, "macB" to 200L)))
        assertEquals("macA", DesktopVaultPick.desktop(desktops, { it }, emptyMap()))
        assertNull(DesktopVaultPick.desktop(emptyList<String>(), { it }, emptyMap()))
    }
}

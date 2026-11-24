package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The phone's copy of its Haven's rank, read with the engine's own checks (trustrank.CheckHandoff). */
class TrustRankCopyTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a')
    private fun file(account: String = me, version: Int = 2, maxHop: Int = 4, rows: String = "[\"${pk('b')}\",80.5,2],[\"${pk('c')}\",47,4]") =
        "{\"account\":\"$account\",\"builtAt\":1795300000,\"version\":$version,\"params\":{},\"maxHop\":$maxHop,\"people\":[$rows],\"viewBar\":55,\"floor\":45}"

    @Test fun `a good copy reads, every field`() {
        val copy = TrustRankCopy.parse(file(), me)!!
        assertEquals(1795300000L, copy.builtAt)
        assertEquals(4, copy.maxHop)
        assertEquals(45.0, copy.floor, 0.0)
        assertEquals(TrustRankCopy.Person(80.5, 2), copy[pk('b')])
        assertEquals(TrustRankCopy.Person(47.0, 4), copy[pk('c').uppercase()])
        assertNull(copy[pk('d')])
    }

    @Test fun `anything that would not pass the engine's checks is refused whole`() {
        for ((why, text) in listOf(
            "another account" to file(account = pk('z')),
            "another version" to file(version = 3),
            "maxHop past 6" to file(maxHop = 7),
            "a ring past maxHop" to file(maxHop = 3),
            "ring 0" to file(rows = "[\"${pk('b')}\",50,0]"),
            "score over 100" to file(rows = "[\"${pk('b')}\",100.5,2]"),
            "not a pubkey" to file(rows = "[\"../x\",50,2]"),
            "a short row" to file(rows = "[\"${pk('b')}\",50]"),
            "a score as text" to file(rows = "[\"${pk('b')}\",\"50\",2]"),
            "version as text" to file().replace("\"version\":2", "\"version\":\"2\""),
            "maxHop as text" to file().replace("\"maxHop\":4", "\"maxHop\":\"4\""),
            "builtAt as text" to file().replace("\"builtAt\":1795300000", "\"builtAt\":\"1795300000\""),
            "not JSON" to "nope",
        )) assertNull(why, TrustRankCopy.parse(text, me))
    }

    private fun withGlobe(globe: String, maxHop: Int = 5) =
        file(maxHop = maxHop).replace("\"viewBar\"", "\"globe\":[$globe],\"viewBar\"")
    private fun g(c: Char, score: String = "30", hop: String = "3", via: String = "\"${pk('b')}\"") = "[\"${pk(c)}\",$score,$hop,$via]"

    @Test fun `the globe list reads in order and never reaches the feed rows`() {
        val copy = TrustRankCopy.parse(withGlobe(g('d') + "," + g('e', "12.5", "5", "\"${pk('d')}\"")), me)!!
        assertEquals(listOf(pk('d'), pk('e')), copy.globe.map { it.pubkey })
        assertEquals(TrustRankCopy.GlobeRow(pk('e'), 12.5, 5, pk('d')), copy.globeRow(pk('e').uppercase()))
        assertNull("get() is the feed's rows only", copy[pk('d')])
        assertEquals(2, copy.people.size)
        assertEquals("no field: an older engine", emptyList<TrustRankCopy.GlobeRow>(), TrustRankCopy.parse(file(), me)!!.globe)
    }

    @Test fun `a bad globe row refuses the whole file, as the engine's check does`() {
        for ((why, text) in listOf(
            "hop 1" to withGlobe(g('d', hop = "1")),
            "hop 6" to withGlobe(g('d', hop = "6"), maxHop = 6),
            "past maxHop" to withGlobe(g('d', hop = "5"), maxHop = 4),
            "score over 100" to withGlobe(g('d', score = "101")),
            "score as text" to withGlobe(g('d', score = "\"30\"")),
            "empty via" to withGlobe(g('d', via = "\"\"")),
            "via not hex" to withGlobe(g('d', via = "\"../x\"")),
            "a short row" to withGlobe("[\"${pk('d')}\",30,3]"),
            "not a list" to file(maxHop = 5).replace("\"viewBar\"", "\"globe\":{},\"viewBar\""),
        )) assertNull(why, TrustRankCopy.parse(text, me))
    }

    @Test fun `at most 2,700 globe rows, the number in the contract`() {
        val contract = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "docs/MESH_COPY_V2_CONTRACT.md") }.first { it.exists() }.readText()
        val n = Regex("""most ([0-9,]+) globe rows""").find(contract.replace(Regex("\\s+"), " "))!!.groupValues[1].replace(",", "").toInt()
        assertEquals(n, TrustRankCopy.MAX_GLOBE_ROWS)
        val hex = "0123456789abcdef"
        fun key(i: Int) = (0 until 64).map { hex[(i shr ((it % 4) * 4)) and 15] }.joinToString("")
        fun rows(k: Int) = (0 until k).joinToString(",") { "[\"${key(it)}\",30,3,\"${pk('b')}\"]" }
        assertEquals(n, TrustRankCopy.parse(withGlobe(rows(n)), me)!!.globe.size)
        assertNull(TrustRankCopy.parse(withGlobe(rows(n + 1)), me))
    }
}

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
            "not JSON" to "nope",
        )) assertNull(why, TrustRankCopy.parse(text, me))
    }
}

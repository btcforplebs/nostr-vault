package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class ParseCacheTest {

    @Test
    fun parsesOncePerKey() {
        val cache = ParseCache<String, List<String>>(10)
        var runs = 0
        val first = cache.getOrPut("note text") { runs++; listOf("a") }
        val second = cache.getOrPut("note text") { runs++; listOf("b") }
        assertEquals(1, runs)
        assertSame(first, second)
    }

    @Test
    fun dropsLeastRecentlyUsedPastTheCap() {
        val cache = ParseCache<String, String>(2)
        var runs = 0
        cache.getOrPut("a") { runs++; "A" }
        cache.getOrPut("b") { runs++; "B" }
        cache.getOrPut("a") { runs++; "A" } // touch a, so b is eldest
        cache.getOrPut("c") { runs++; "C" } // evicts b
        assertEquals(2, cache.size)
        cache.getOrPut("a") { runs++; "A" }
        assertEquals(3, runs)
        cache.getOrPut("b") { runs++; "B" }
        assertEquals(4, runs)
    }
}

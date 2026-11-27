package com.nostrvault.service

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** [GlobalSearchSession.pageFilter]: the REQ filter of one page of the local store walk. */
class GlobalSearchPageFilterTest {
    private val me = "a1".repeat(32)

    @Test
    fun everyonesNotesHaveNoAuthors() {
        val f = GlobalSearchSession.pageFilter(1, null, null)
        assertFalse(f.containsKey("authors"))
        assertEquals(JsonArray(listOf(JsonPrimitive(1))), f["kinds"])
    }

    @Test
    fun myNotesAsksTheStoreForMyKeyOnly() {
        val f = GlobalSearchSession.pageFilter(30023, 500L, setOf(me))
        assertEquals(JsonArray(listOf(JsonPrimitive(me))), f["authors"])
        assertEquals(JsonPrimitive(500L), f["until"])
    }

    @Test
    fun profilePagesNeverCarryAuthors() {
        assertFalse(GlobalSearchSession.pageFilter(0, null, setOf(me)).containsKey("authors"))
    }
}

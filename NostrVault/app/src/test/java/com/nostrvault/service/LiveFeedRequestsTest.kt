package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Live's Following REQs ask about every follow, not only the first 500. */
class LiveFeedRequestsTest {
    private fun hex(i: Int) = i.toString(16).padStart(64, '0')

    /** (sub id, authors, #p) for each REQ. */
    private fun parsed(requests: List<Pair<String, String>>) = requests.map { (id, req) ->
        val array = Json.parseToJsonElement(req).jsonArray
        assertEquals("REQ", array[0].jsonPrimitive.content)
        assertEquals(id, array[1].jsonPrimitive.content)
        val filters = array.drop(2).map { it.jsonObject }
        fun values(key: String) = filters.flatMap { f -> f[key]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList() }
        Triple(id, values("authors"), values("#p"))
    }

    /** Logen follows 1,054 and The Lot Radio is #1041 (2026-11-01); take(500) never asked for it. */
    @Test
    fun aFollowAt1041Of1054IsAskedForByAuthorAndByP() {
        val follows = (1..1054).map(::hex)
        val bot = follows[1040]
        val reqs = parsed(LiveFeedService.liveRequests("live-x", LinkedHashSet(follows)))

        assertTrue(reqs.any { bot in it.second })
        assertTrue(reqs.any { bot in it.third })
        // Every follow is asked about, once, in REQs of at most 500.
        assertEquals(follows, reqs.flatMap { it.second })
        assertEquals(follows, reqs.flatMap { it.third })
        assertTrue(reqs.all { it.second.size <= LiveFeedService.AUTHORS_PER_REQ })
        assertEquals(3, reqs.size)
        assertEquals(3, reqs.map { it.first }.toSet().size)
    }

    @Test
    fun globalIsOneOpenRequest() {
        for (following in listOf(null, emptyList<String>())) {
            val reqs = parsed(LiveFeedService.liveRequests("live-x", following))
            assertEquals(listOf(Triple("live-x", emptyList<String>(), emptyList<String>())), reqs)
        }
    }
}

package com.nostrvault.relay

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class VaultStoreReadTest {
    private fun ev(id: String, at: Long, content: String = "") =
        Json.parseToJsonElement("""{"id":"$id","pubkey":"p","created_at":$at,"kind":1,"tags":[],"content":"$content","sig":"s"}""").jsonObject

    private fun ids(events: List<JsonObject>) = events.map { it["id"]!!.jsonPrimitive.content }

    @Test
    fun `the request carries the filters as they are`() {
        assertEquals(
            """{"filters":[{"kinds":[1],"limit":5},{"#p":["aa"]}]}""",
            VaultStoreRead.request(listOf("""{"kinds":[1],"limit":5}""", """{"#p":["aa"]}""")),
        )
    }

    @Test
    fun `an answer's events come back, emoji and all`() {
        val events = VaultStoreRead.events("""{"events":[${ev("a", 2, "gm 🚀")},${ev("b", 1)}]}""")!!
        assertEquals(listOf("a", "b"), ids(events))
        assertEquals("gm 🚀", events[0]["content"]!!.jsonPrimitive.content)
    }

    @Test
    fun `not ready, any error or a bad answer reads over the socket`() {
        assertNull(VaultStoreRead.events("""{"error":"vault read not ready"}"""))
        assertNull(VaultStoreRead.events("""{"error":"too many filters"}"""))
        assertNull(VaultStoreRead.events("""{"events":[],"error":"x"}"""))
        assertNull(VaultStoreRead.events("""{}"""))
        assertNull(VaultStoreRead.events("not json"))
        assertNull(VaultStoreRead.events("""[1,2]"""))
    }

    @Test
    fun `an empty store is an answer, not an error`() {
        assertEquals(emptyList<JsonObject>(), VaultStoreRead.events("""{"events":[]}"""))
    }

    @Test
    fun `answers of several calls merge, one per id, newest first`() {
        val merged = VaultStoreRead.merge(listOf(listOf(ev("a", 5), ev("b", 1)), listOf(ev("c", 9), ev("a", 5))))
        assertEquals(listOf("c", "a", "b"), ids(merged))
    }

    @Test
    fun `old saved screens are deleted, other files stay`() {
        val tmp = TemporaryFolder().apply { create() }
        try {
            val dir = tmp.root
            File(dir, "vault-snapshots").mkdirs()
            File(dir, "vault-snapshots/vault-notes-${"a".repeat(64)}.json").writeText("{}")
            File(dir, "vault_snapshot.json").writeText("{}")
            File(dir, "feed_snapshot.json").writeText("{}")
            VaultStoreRead.removeOldSavedScreens(dir)
            assertEquals(listOf("feed_snapshot.json"), dir.list()!!.toList())
        } finally {
            tmp.delete()
        }
    }
}

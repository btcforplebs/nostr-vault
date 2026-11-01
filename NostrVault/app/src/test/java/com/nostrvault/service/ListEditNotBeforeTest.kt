package com.nostrvault.service

import com.nostrvault.relay.RelayDraft
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * MAX_SKEW on Android, as on iOS and web (Tron, #1469): a list edit is signed at max(now, base + 1), so a base
 * dated a little ahead (another device's fast clock) can't keep its place over the edit. And a list's own relays
 * are its 10002 write relays only.
 */
class ListEditNotBeforeTest {

    private fun createdAt(json: String) = Json.parseToJsonElement(json).jsonObject["created_at"]!!.jsonPrimitive.long

    @Test
    fun `an edit is signed after a base dated ahead`() {
        val now = System.currentTimeMillis() / 1000
        val ahead = now + 600
        assertEquals(ahead, createdAt(EventPublisher.buildUnsignedEvent("ab", 3, "", emptyList(), notBefore = ahead)))
        // A base in the past changes nothing: signed at now.
        val past = createdAt(EventPublisher.buildUnsignedEvent("ab", 3, "", emptyList(), notBefore = now - 600))
        assertTrue(past >= now && past < now + 5)
        // Gift wraps keep their backdating.
        assertTrue(createdAt(EventPublisher.buildUnsignedEvent("ab", 1059, "", emptyList(), notBefore = ahead)) <= now + 5)
    }

    @Test
    fun `notBefore is one second after the base`() {
        assertEquals(0L, ListMerge.notBefore(null))
        assertEquals(1001L, ListMerge.notBefore(NostrEvent("id", "ab", 1000, 3, emptyList(), "", "sig")))
    }

    @Test
    fun `a copy skipped for being dated ahead is not settled`() {
        val indexers = RelayDraft.INDEXERS
        assertTrue(RelayDraft.settled(found = false, answeredBy = indexers))
        assertFalse(RelayDraft.settled(found = false, answeredBy = indexers, ahead = true))
    }

    private val root = File("src/main/java/com/nostrvault/service")
    private fun flat(path: String) = File(root, path).readText().replace(Regex("\\s+"), " ")

    /** Each sign call in [path] for [kind], from its name to its closing parenthesis. */
    private fun calls(path: String, kind: String): List<String> {
        val text = flat(path)
        return Regex("\\b(signEventAsync|signAndPost)\\( ?kind = $kind\\b").findAll(text).map { m ->
            var depth = 0
            var end = m.range.last
            for (i in text.indices.drop(text.indexOf('(', m.range.first))) {
                if (text[i] == '(') depth++
                if (text[i] == ')') { depth--; if (depth == 0) { end = i; break } }
            }
            text.substring(m.range.first, end + 1)
        }.toList()
    }

    @Test
    fun `every list edit signs with notBefore`() {
        val sites = listOf(
            "FeedServiceFollow.kt" to "3",
            "InterestListService.kt" to "InterestList.KIND",
            "nostr/NostrServiceListPublishing.kt" to "10000",
            "nostr/NostrServiceListPublishing.kt" to "kind", // publishMergedList: 10006, 10063 and the rest
            "nostr/NostrServiceListPublishing.kt" to "10002",
            "nostr/NostrServiceListPublishing.kt" to "10050",
        )
        for ((path, kind) in sites) {
            val found = calls(path, kind)
            assertTrue("$path kind $kind: no sign call found", found.isNotEmpty())
            found.forEach { assertTrue("$path: $it", "notBefore =" in it) }
        }
        assertFalse("the follow path no longer waits", "followListSignDelayMs" in flat("FeedServiceFollow.kt"))
    }

    @Test
    fun `own relays are the write relays only`() {
        val text = flat("nostr/NostrServiceListPublishing.kt")
        val body = text.substringAfter("fun NostrService.ownListRelaysImpl(").substringBefore("fun NostrService.relayListLookupRelays")
        assertTrue(body, "outboxRelays.value[account]" in body)
        assertFalse(body, "relayLists" in body)
        assertFalse(body, "r + w" in body)
    }
}

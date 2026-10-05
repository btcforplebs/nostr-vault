package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Relay tab > Given (iOS #294-#296). */
class RelayGivenTest {

    // ── Liked posts: where to look ─────────────────────────────────

    @Test
    fun likedPostsAreAskedOfLocalFeedThenFeedRelaysThenAuthors() {
        val urls = RelayGiven.likedNoteRelays(
            localRoot = "ws://127.0.0.1:3355",
            localFeed = "ws://127.0.0.1:3355/feed",
            feedRelays = listOf("wss://relay.primal.net"),
            missingIds = listOf("n1", "n2"),
            likedAuthor = mapOf("n1" to "alice", "n2" to "bob"),
            outboxRelays = mapOf(
                "alice" to listOf("wss://a1", "wss://a2", "wss://a3"),
                "bob" to listOf("wss://relay.primal.net", "wss://b1"),
            ),
        )
        assertEquals(
            listOf(
                "ws://127.0.0.1:3355", "ws://127.0.0.1:3355/feed", "wss://relay.primal.net",
                "wss://a1", "wss://a2", "wss://b1",
            ),
            urls,
        )
    }

    @Test
    fun authorRelaysAreCappedAtSix() {
        val ids = (1..10).map { "n$it" }
        val urls = RelayGiven.likedNoteRelays(
            localRoot = null, localFeed = null, feedRelays = listOf("wss://feed"),
            missingIds = ids,
            likedAuthor = ids.associateWith { "author-$it" },
            outboxRelays = ids.associate { "author-$it" to listOf("wss://$it-x", "wss://$it-y") },
        )
        assertEquals(1 + 6, urls.size)
    }

    @Test
    fun noFeedRelaysFallsBack() {
        val urls = RelayGiven.likedNoteRelays(null, null, emptyList(), emptyList(), emptyMap(), emptyMap())
        assertEquals(RelayGiven.FALLBACK_FEED_RELAYS, urls)
    }

    // ── Zap receipt relays ─────────────────────────────────────────

    @Test
    fun loopbackOwnRelayIsLeftOutOfTheZapRequest() {
        val relays = RelayGiven.zapReceiptRelays(
            ownRelay = "ws://127.0.0.1:3355",
            feedRelays = listOf("wss://relay.primal.net"),
            myInbox = listOf("wss://inbox.example.com", "wss://relay.primal.net/"),
            recipientInbox = listOf("wss://r1", "wss://r2", "wss://r3", "wss://r4"),
        )
        assertEquals(
            listOf("wss://relay.primal.net", "wss://inbox.example.com", "wss://r1", "wss://r2", "wss://r3"),
            relays,
        )
    }

    @Test
    fun publicOwnRelayStaysAndTheListStopsAtTen() {
        val relays = RelayGiven.zapReceiptRelays(
            ownRelay = "wss://vault.example.com",
            feedRelays = (1..12).map { "wss://feed$it" },
            myInbox = emptyList(),
            recipientInbox = emptyList(),
        )
        assertEquals("wss://vault.example.com", relays.first())
        assertEquals(10, relays.size)
    }

    @Test
    fun privateAndLocalHostsAreNotPublic() {
        for (url in listOf(
            "ws://127.0.0.1:3355", "ws://localhost:3355", "ws://10.0.0.5", "ws://192.168.1.2:4869",
            "ws://172.20.0.1", "ws://169.254.1.1", "ws://100.64.0.1", "ws://my-mac.local",
            "ws://[::1]:3355", "not a url",
        )) assertFalse(url, RelayGiven.isPublicRelay(url))
        for (url in listOf("wss://relay.primal.net", "wss://172.32.0.1", "wss://8.8.8.8")) {
            assertTrue(url, RelayGiven.isPublicRelay(url))
        }
    }

    // ── Given zaps: order and amounts ──────────────────────────────

    @Test
    fun aPostRisesWhenYouZapItAgain() {
        val last = RelayGiven.lastZapTimes(
            walletTimes = mapOf("old" to 100L),
            receiptZaps = listOf("old" to 500L, "mid" to 300L),
        )
        // created_at stands in for a post only this app's list knows.
        val created = mapOf("old" to 10L, "mid" to 20L, "local" to 400L)
        val order = RelayGiven.newestZapFirst(listOf("mid", "local", "old"), last, { it }, { created.getValue(it) })
        assertEquals(listOf("old", "local", "mid"), order)
    }

    @Test
    fun walletAmountsWinAndZeroIsUnknown() {
        val amounts = RelayGiven.givenAmounts(
            localZapped = mapOf("a" to 21, "b" to 0, "c" to 100),
            walletAmounts = mapOf("c" to 121L),
        )
        assertEquals(mapOf("a" to 21L, "c" to 121L), amounts)
    }

    // ── Cached events ──────────────────────────────────────────────

    @Test
    fun cachedEventParsesOnlyWhenWhole() {
        val json = """{"id":"abc","pubkey":"pk","created_at":1700000000,"kind":1,"tags":[["p","x"]],"content":"hi","sig":"s"}"""
        val event = RelayGiven.eventFromJson(json)
        assertEquals("abc", event?.id)
        assertEquals(listOf(listOf("p", "x")), event?.tags)
        assertNull(RelayGiven.eventFromJson("""{"id":"abc","pubkey":"pk","kind":1,"tags":[],"content":"hi","sig":"s"}"""))
        assertNull(RelayGiven.eventFromJson("not json"))
    }

    @Test
    fun onlyEventIdsCountAsZappedPosts() {
        assertTrue(RelayGiven.isEventId("a".repeat(64)))
        assertFalse(RelayGiven.isEventId(""))
        assertFalse(RelayGiven.isEventId("A".repeat(64)))
        assertFalse(RelayGiven.isEventId("30311:" + "b".repeat(64) + ":d"))
        assertFalse(RelayGiven.isEventId("b".repeat(63)))
    }
}

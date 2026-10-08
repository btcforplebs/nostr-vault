package com.nostrvault.data.model

import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as iOS `TopicFeedFilterTests`. */
class TopicFeedFilterTest {
    private fun post(id: String, pubkey: String, content: String, hashtags: Int = 1) =
        TopicFeedFilter.Post(id, pubkey, content, (0 until hashtags).map { listOf("t", "tag$it") })

    /** People follow people; bots and farms don't. Unknown waits. */
    @Test fun authorsMustFollowTwenty() {
        val posts = listOf(post("a", "person", "street photo"), post("b", "bot", "price tick"), post("c", "unknown", "hi there"))
        assertEquals(listOf("a"), TopicFeedFilter.shown(posts, mapOf("person" to 120, "bot" to 0)))
        assertEquals(listOf("a"), TopicFeedFilter.shown(posts, mapOf("person" to 20, "bot" to 19)))
        // Content bots follow exactly 10 to look like people.
        assertEquals(emptyList<String>(), TopicFeedFilter.shown(posts, mapOf("person" to 10, "bot" to 10)))
    }

    @Test fun hashtagStuffing() {
        val posts = listOf(post("a", "p", "five tags", hashtags = 5), post("b", "q", "six tags", hashtags = 6))
        assertEquals(listOf("a"), TopicFeedFilter.shown(posts, mapOf("p" to 50, "q" to 50)))
    }

    /** A non-media site linked by 4+ accounts is a farm; images aren't. */
    @Test fun linkFarms() {
        val posts = (0 until 4).map { post("f$it", "farm$it", "thank you donors https://api.gifts.example/m/$it") } +
            (0 until 4).map { post("i$it", "cam$it", "sunset number $it https://blossom.example/$it.jpg") }
        val counts = posts.associate { it.pubkey to 50 }
        assertEquals(listOf("i0", "i1", "i2", "i3"), TopicFeedFilter.shown(posts, counts))
    }

    /** The same text once, even when the link in it changes. */
    @Test fun copiesShowOnce() {
        val posts = listOf(post("a", "p", "GM nostr https://x.example/1"), post("b", "q", "gm   NOSTR https://x.example/2"))
        assertEquals(listOf("a"), TopicFeedFilter.shown(posts, mapOf("p" to 50, "q" to 50)))
    }

    @Test fun twoPerPerson() {
        val posts = (0 until 5).map { post("$it", "busy", "post number $it") }
        assertEquals(listOf("0", "1"), TopicFeedFilter.shown(posts, mapOf("busy" to 300)))
    }

    @Test fun adultPostsAreHidden() {
        val posts = listOf(
            TopicFeedFilter.Post("a", "p", "say hi", listOf(listOf("t", "NSFW"))),
            TopicFeedFilter.Post("b", "q", "beach", listOf(listOf("content-warning", ""))),
            TopicFeedFilter.Post("c", "r", "sunset", listOf(listOf("t", "photography"))),
        )
        assertEquals(listOf("c"), TopicFeedFilter.shown(posts, mapOf("p" to 50, "q" to 50, "r" to 50)))
    }

    /** A game posting its player's score is the app talking, not the person. */
    @Test fun appMadePostsAreHidden() {
        val game = TopicFeedFilter.Post("g", "p", "I just obliterated 197 zombies https://plebsvszombies.cc/x",
            listOf(listOf("client", "Plebs vs. Zombies")))
        val person = TopicFeedFilter.Post("h", "q", "my essay https://trbouma.substack.com/p/x",
            listOf(listOf("client", "Amethyst")))
        val photo = TopicFeedFilter.Post("i", "r", "walk https://i.nostr.build/a.jpg",
            listOf(listOf("client", "nostr.build")))
        assertTrue(TopicFeedFilter.isAppMade(game))
        assertFalse(TopicFeedFilter.isAppMade(person))
        assertFalse("image links are not sites", TopicFeedFilter.isAppMade(photo))
        val damus = TopicFeedFilter.Post("d", "s", "look https://damus.io/note1abc", listOf(listOf("client", "Damus")))
        assertFalse("a person sharing a link from their own app", TopicFeedFilter.isAppMade(damus))
        assertEquals(listOf("h", "i"), TopicFeedFilter.shown(listOf(game, person, photo), mapOf("p" to 50, "q" to 50, "r" to 50)))
    }

    /** Posts two or more people responded to lead; the rest follow, in order. */
    @Test fun respondedToGoFirst() {
        val ids = listOf("new", "liked", "one", "older", "loved")
        assertEquals(listOf("liked", "loved", "new", "one", "older"),
            TopicFeedFilter.ordered(ids, mapOf("liked" to 2, "one" to 1, "loved" to 9)))
        assertEquals(ids, TopicFeedFilter.ordered(ids, emptyMap()))
    }

    /** A zap counts as the signer of the zap request inside the receipt,
     *  never an unsigned name the wallet wrote. */
    @Test fun zapResponderIsTheSignedSender() {
        val signed = """{"kind":9734,"pubkey":"bob","tags":[],"sig":"ok"}"""
        val forged = """{"kind":9734,"pubkey":"mallory","tags":[],"sig":"bad"}"""
        val valid: (String) -> Boolean = { it.contains("\"sig\":\"ok\"") }
        fun receipt(description: String?, p: String? = null): JsonObject {
            val tags = buildList {
                add("""["e","x"]""")
                if (description != null) add("""["description",${Json.encodeToString(String.serializer(), description)}]""")
                if (p != null) add("""["P","$p"]""")
            }
            return Json.parseToJsonElement("""{"kind":9735,"pubkey":"wallet","tags":[${tags.joinToString(",")}]}""").jsonObject
        }
        assertEquals("bob", TopicFeedFilter.responder(receipt(signed), valid))
        assertEquals("bob", TopicFeedFilter.responder(receipt(signed, p = "bob"), valid))
        assertNull("P disagrees", TopicFeedFilter.responder(receipt(signed, p = "alice"), valid))
        assertNull("unsigned request", TopicFeedFilter.responder(receipt(forged), valid))
        assertNull("P alone is unsigned", TopicFeedFilter.responder(receipt(null, p = "alice"), valid))
        val like = Json.parseToJsonElement("""{"kind":7,"pubkey":"carol","tags":[["e","x"]]}""").jsonObject
        assertEquals("carol", TopicFeedFilter.responder(like, valid))
    }

    /** Anyone can publish a receipt: an odd one is no responder, not a crash. */
    @Test fun malformedZapIsIgnored() {
        val valid: (String) -> Boolean = { true }
        for (description in listOf("""{"kind":{}}""", """{"kind":9734,"pubkey":[]}""", "[]", "not json")) {
            val receipt = Json.parseToJsonElement(
                """{"kind":9735,"pubkey":"wallet","tags":[["description",${Json.encodeToString(String.serializer(), description)}]]}""",
            ).jsonObject
            assertNull(description, TopicFeedFilter.responder(receipt, valid))
        }
        val oddKind = Json.parseToJsonElement("""{"kind":[9735],"pubkey":{},"tags":[]}""").jsonObject
        assertNull(TopicFeedFilter.responder(oddKind, valid))
    }

    /** As lenient as iOS URL(string:): a farm can't hide behind odd characters. */
    @Test fun oddLinksStillCount() {
        assertEquals(setOf("gift_farm.example"), TopicFeedFilter.linkDomains("give https://gift_farm.example/a"))
        assertEquals(setOf("x.example"), TopicFeedFilter.linkDomains("pay https://x.example/a|b?q={1}"))
        assertEquals(setOf("x.example"), TopicFeedFilter.linkDomains("https://user@X.example:8080/p"))
    }

    @Test fun linkDomains() {
        assertEquals(setOf("example.com"),
            TopicFeedFilter.linkDomains("see https://Example.com/a and https://i.nostr.build/x.PNG"))
    }
}

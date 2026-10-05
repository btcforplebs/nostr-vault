package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors iOS FeedOutboxPlanTests (#227). */
class FeedOutboxPlanTest {
    private val feed = listOf("wss://relay.primal.net", "wss://nos.lol")
    private val fallback = FeedOutboxPlan.FALLBACK_RELAY

    /**
     * A follow who writes to a feed relay is already covered and costs no
     * extra socket; one who writes elsewhere gets that relay, asked only for them.
     */
    @Test
    fun `only follows the feed relays miss are asked elsewhere`() {
        val plan = FeedOutboxPlan.plan(
            follows = listOf("a", "b", "c"),
            writeRelays = mapOf("a" to listOf("wss://nos.lol/"), "b" to listOf("wss://relay.damus.io"), "c" to emptyList()),
            feedRelays = feed,
        )
        assertEquals(mapOf("wss://relay.damus.io" to listOf("b"), fallback to listOf("c")), plan)
    }

    /** Case and a trailing slash do not make a relay a different one. */
    @Test
    fun `feed relay match ignores case and trailing slash`() {
        val plan = FeedOutboxPlan.plan(
            follows = listOf("a"),
            writeRelays = mapOf("a" to listOf("WSS://Relay.Primal.NET/")),
            feedRelays = feed,
        )
        assertTrue(plan.isEmpty())
    }

    /**
     * The relay reaching the most uncovered follows is picked first, and a
     * follow already reached is not asked again on a later pick.
     */
    @Test
    fun `greedy cover picks the widest relay and asks each follow once`() {
        val plan = FeedOutboxPlan.plan(
            follows = listOf("a", "b", "c", "d"),
            writeRelays = mapOf(
                "a" to listOf("wss://relay.damus.io", "wss://x.example"),
                "b" to listOf("wss://relay.damus.io"),
                "c" to listOf("wss://relay.damus.io", "wss://y.example"),
                "d" to listOf("wss://y.example"),
            ),
            feedRelays = feed,
        )
        assertEquals(listOf("a", "b", "c"), plan["wss://relay.damus.io"])
        assertEquals(listOf("d"), plan["wss://y.example"])
        assertNull(plan["wss://x.example"])
        val asked = plan.values.flatten()
        assertEquals("a follow is asked on one extra relay only", asked.toSet().size, asked.size)
    }

    @Test
    fun `extra relays are capped`() {
        val lists = (0 until 20).associate { "p$it" to listOf("wss://r$it.example") }
        val plan = FeedOutboxPlan.plan(follows = lists.keys, writeRelays = lists, feedRelays = feed)
        assertEquals(FeedOutboxPlan.MAX_EXTRA_RELAYS, plan.size)
    }

    /** Private and unreachable relays are somebody else's setup. */
    @Test
    fun `unreachable relays are never picked`() {
        val lists = mapOf(
            "a" to listOf(
                "ws://plain.example", "wss://abc.onion", "wss://127.0.0.1:7777",
                "wss://192.168.1.4", "wss://localhost", "wss://box.local",
            ),
        )
        val plan = FeedOutboxPlan.plan(follows = listOf("a"), writeRelays = lists, feedRelays = feed)
        assertEquals("no usable relay = no list", mapOf(fallback to listOf("a")), plan)
    }

    /**
     * nos.lol and nostr.mom were down on 2026-10-04 while feed relays; a
     * follow reached only through one of them was not reached at all.
     */
    @Test
    fun `a down feed relay reaches nobody`() {
        val lists = mapOf("a" to listOf("wss://nos.lol", "wss://relay.damus.io"))
        assertTrue(FeedOutboxPlan.plan(follows = listOf("a"), writeRelays = lists, feedRelays = feed).isEmpty())
        val plan = FeedOutboxPlan.plan(
            follows = listOf("a"), writeRelays = lists, feedRelays = feed,
            unreachableRelays = listOf("wss://nos.lol/"),
        )
        assertEquals(mapOf("wss://relay.damus.io" to listOf("a")), plan)
        val onlyDown = FeedOutboxPlan.plan(
            follows = listOf("b"), writeRelays = mapOf("b" to listOf("wss://relay.damus.io")),
            feedRelays = feed, unreachableRelays = listOf("wss://relay.damus.io"),
        )
        assertEquals("never pick a down relay", mapOf(fallback to listOf("b")), onlyDown)
    }

    /**
     * Follows with no relay list go to the fallback, which also takes any
     * listed follow it reaches — so they are not asked twice.
     */
    @Test
    fun `unlisted follows go to the fallback once`() {
        val plan = FeedOutboxPlan.plan(
            follows = listOf("a", "b", "c"),
            writeRelays = mapOf("b" to listOf(fallback, "wss://relay.damus.io"), "c" to listOf("wss://relay.damus.io")),
            feedRelays = feed,
        )
        assertEquals(listOf("a", "b"), plan[fallback])
        assertEquals(listOf("c"), plan["wss://relay.damus.io"])
        assertTrue(
            "a fallback already among the feed relays costs nothing",
            FeedOutboxPlan.plan(follows = listOf("a"), writeRelays = emptyMap(), feedRelays = feed + fallback).isEmpty(),
        )
        assertTrue(
            FeedOutboxPlan.plan(follows = listOf("a"), writeRelays = emptyMap(), feedRelays = feed, fallbackRelay = null).isEmpty(),
        )
    }

    @Test
    fun `the fallback counts toward the cap`() {
        val lists = (0 until 20).associate { "p$it" to listOf("wss://r$it.example") }
        val plan = FeedOutboxPlan.plan(follows = lists.keys + "unlisted", writeRelays = lists, feedRelays = feed)
        assertEquals(FeedOutboxPlan.MAX_EXTRA_RELAYS, plan.size)
        assertEquals(listOf("unlisted"), plan[fallback])
    }

    /** Same inputs, same relays: map order must not change the pick. */
    @Test
    fun `ties are broken the same way every time`() {
        val lists = mapOf("a" to listOf("wss://b.example"), "b" to listOf("wss://a.example"))
        repeat(20) {
            val plan = FeedOutboxPlan.plan(follows = listOf("a", "b"), writeRelays = lists, feedRelays = feed, maxExtraRelays = 1)
            assertEquals(listOf("wss://a.example"), plan.keys.toList())
        }
    }
}

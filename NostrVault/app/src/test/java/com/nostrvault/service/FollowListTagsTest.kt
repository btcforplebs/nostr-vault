package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A kind 3 carries more than follows (Amethyst writes `t` and `a` tags). Only
 * 64-hex `p` tags are follows, and a publish keeps every other tag (C1).
 */
class FollowListTagsTest {
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val carol = "c".repeat(64)
    private val me = "e".repeat(64)

    @Test fun onlyHexPTagsAreFollows() {
        val tags = listOf(
            listOf("p", alice, "wss://relay.example", "alice"),
            listOf("t", "bitcoin"),
            listOf("a", "30000:$bob:friends"),
            listOf("p", "bitcoin"),
            listOf("p", "B".repeat(64)),
            listOf("p"),
        )
        val result = ContactManager.parseContactList(tags, me, emptyList())
        assertEquals(listOf(alice, me), result.pubkeys)
        assertEquals(1, result.relayPTagCount)
    }

    @Test fun publishKeepsOtherTagsAndHints() {
        val loaded = listOf(
            listOf("t", "bitcoin"),
            listOf("p", alice, "wss://relay.example", "alice"),
            listOf("a", "30000:$bob:friends"),
            listOf("p", bob),
        )
        assertEquals(
            listOf(
                listOf("t", "bitcoin"),
                listOf("p", alice, "wss://relay.example", "alice"),
                listOf("a", "30000:$bob:friends"),
                listOf("p", carol),
            ),
            ContactManager.contactListTags(listOf(alice, carol), loaded),
        )
    }

    @Test fun publishDropsJunkPTagsAndDuplicates() {
        val loaded = listOf(listOf("p", "bitcoin"), listOf("p", alice), listOf("p", alice, "wss://x"))
        assertEquals(listOf(listOf("p", alice)), ContactManager.contactListTags(listOf(alice), loaded))
    }

    @Test fun noLoadedTagsIsPlainPTags() {
        assertEquals(listOf(listOf("p", alice), listOf("p", bob)), ContactManager.contactListTags(listOf(alice, bob), emptyList()))
    }

    @Test fun signDelayWaitsForTheNextSecond() {
        assertEquals(0L, ContactManager.followListSignDelayMs(nowMs = 101_000, lastCreatedAt = 100))
        assertEquals(700L, ContactManager.followListSignDelayMs(nowMs = 100_300, lastCreatedAt = 100))
        assertEquals(1000L, ContactManager.followListSignDelayMs(nowMs = 100_000, lastCreatedAt = 100))
        // A clock far behind the last list is not waited out.
        assertEquals(0L, ContactManager.followListSignDelayMs(nowMs = 50_000, lastCreatedAt = 100))
    }
}

package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors iOS `InterestListTests`. */
class InterestListTest {
    @Test fun followAddsLowercaseTagAndKeepsOtherTags() {
        val list = InterestList(tags = listOf(listOf("t", "bitcoin"), listOf("a", "30015:abc:music")), content = "secret", createdAt = 10)
        val next = list.setting("#Nostr", followed = true)
        assertEquals(listOf(listOf("t", "bitcoin"), listOf("a", "30015:abc:music"), listOf("t", "nostr")), next.tags)
        assertEquals("secret", next.content)
        assertEquals(listOf("bitcoin", "nostr"), next.hashtags)
    }

    @Test fun followIsIdempotentAcrossCase() {
        val list = InterestList(tags = listOf(listOf("t", "Bitcoin")))
        assertEquals(list, list.setting("bitcoin", followed = true))
        assertTrue("BITCOIN" in list)
    }

    @Test fun unfollowRemovesEveryCaseVariantOnly() {
        val list = InterestList(tags = listOf(listOf("t", "Bitcoin"), listOf("t", "bitcoin"), listOf("t", "art"), listOf("a", "30015:x:y")))
        val next = list.setting("bitcoin", followed = false)
        assertEquals(listOf(listOf("t", "art"), listOf("a", "30015:x:y")), next.tags)
    }

    @Test fun emptyNameIsIgnored() {
        val list = InterestList(tags = listOf(listOf("t", "art")))
        assertEquals(list, list.setting(" # ", followed = true))
        assertEquals(list, list.setting("", followed = false))
    }

    @Test fun hashtagsSkipsMalformedAndDuplicateTags() {
        val list = InterestList(tags = listOf(listOf("t"), listOf("t", ""), listOf("t", "Art"), listOf("t", "art"), listOf("p", "abc")))
        assertEquals(listOf("art"), list.hashtags)
    }
}

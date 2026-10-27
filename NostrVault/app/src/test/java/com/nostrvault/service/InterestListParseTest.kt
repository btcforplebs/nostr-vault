package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** Adding many hashtags at once in the Hashtags feed. Mirrors iOS `InterestListParseTests`. */
class InterestListParseTest {
    @Test fun splitsOnSpacesCommasNewlinesAndHashes() {
        val parsed = InterestList.parseHashtags("#Bitcoin #nostr, art\nphotography;music #a#b")
        assertEquals(listOf("bitcoin", "nostr", "art", "photography", "music", "a", "b"), parsed.hashtags)
        assertEquals(emptyList<String>(), parsed.rejected)
    }

    @Test fun keepsTypedOrderAndDropsRepeatsAcrossCase() {
        assertEquals(listOf("nostr", "art"), InterestList.parseHashtags("nostr #ART Nostr art").hashtags)
    }

    @Test fun piecesThatCannotBeHashtagsAreRejectedAsTyped() {
        val parsed = InterestList.parseHashtags("#123 c++ #zap_stream café 2024btc")
        assertEquals(listOf("zap_stream", "café", "2024btc"), parsed.hashtags)
        assertEquals(listOf("123", "c++"), parsed.rejected)
    }

    @Test fun blankInputIsNothing() {
        val parsed = InterestList.parseHashtags("  #  ,, \n")
        assertEquals(emptyList<String>(), parsed.hashtags)
        assertEquals(emptyList<String>(), parsed.rejected)
    }

    @Test fun allParsedTagsLandInOneListAndKeepTheRest() {
        val list = InterestList(tags = listOf(listOf("t", "art"), listOf("a", "30015:x:y")), content = "secret")
        val next = InterestList.parseHashtags("#art #nostr bitcoin").hashtags
            .fold(list) { acc, tag -> acc.setting(tag, followed = true) }
        assertEquals(listOf("art", "nostr", "bitcoin"), next.hashtags)
        assertEquals(listOf("a", "30015:x:y"), next.tags[1])
        assertEquals("secret", next.content)
    }
}

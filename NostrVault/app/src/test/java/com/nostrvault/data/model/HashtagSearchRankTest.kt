package com.nostrvault.data.model

import com.nostrvault.ui.screens.SearchResultSections
import org.junit.Assert.assertEquals
import org.junit.Test

/** Hashtag order in Search and the Vault (search plan §1c, D6). Mirrors iOS HashtagSearchRankTests (A5). */
class HashtagSearchRankTest {
    @Test fun typedTagThenMostUsedThenAToZ() {
        val counts = mapOf("bitcoiners" to 1, "bitcoinart" to 5, "bitcoin" to 2, "bitcoinbeach" to 5)
        assertEquals(listOf("bitcoin", "bitcoinart", "bitcoinbeach", "bitcoiners"), HashtagSearchRank.order(counts, "bitcoin"))
    }

    @Test fun hashAndCaseInTheQueryDoNotMatter() {
        assertEquals(listOf("nostr", "nostrich"), HashtagSearchRank.order(mapOf("nostr" to 1, "nostrich" to 9), "#Nostr"))
    }

    /** A word of a longer query is exact too, and so are the words run together. */
    @Test fun anyWordOrTheWordsJoinedAreExact() {
        assertEquals(listOf("zap", "zaps", "zapathon"), HashtagSearchRank.order(mapOf("zapathon" to 1, "zap" to 1, "zaps" to 4), "nostr zap"))
        assertEquals(listOf("plebchain", "plebchainradio"), HashtagSearchRank.order(mapOf("plebchainradio" to 7, "plebchain" to 1), "pleb chain"))
    }

    @Test fun countsATagOncePerItem() {
        assertEquals(mapOf("a" to 2, "b" to 1), HashtagSearchRank.counts(listOf(listOf("a", "a", "b"), listOf("a"))) { it })
    }

    @Test fun vaultHashtagsUseTheOrder() {
        val tags = VaultSearchLogic.hashtags(
            listOf(
                "#bitcoiners #bitcoiners" to emptyList(),
                "#bitcoiners" to emptyList(),
                "#bitcoin" to emptyList(),
                "#BitcoinArt" to listOf(listOf("t", "bitcoinart")),
            ),
            "bitcoin",
        )
        assertEquals(listOf("bitcoin", "bitcoiners", "bitcoinart"), tags)
    }

    @Test fun searchTabHashtagsUseTheOrder() {
        val notes = listOf("#nostrich #nostrich", "#nostrich", "#nostr", "#grownostr #grownostr").mapIndexed { i, c ->
            FeedNote.fromEvent("n$i", "a".repeat(64), c, emptyList(), i.toLong(), 1)
        }
        assertEquals(listOf("nostr", "nostrich", "grownostr"), SearchResultSections.hashtags(notes, "#nostr"))
    }
}

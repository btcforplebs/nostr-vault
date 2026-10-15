package com.nostrvault.data.model

import com.nostrvault.data.model.VaultSearchLogic.QueryState
import com.nostrvault.data.model.VaultSearchLogic.Section
import com.nostrvault.data.model.VaultSearchLogic.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of iOS `HavenApp/MediaLogicTests/Tests/MediaLogicTests/VaultSearchLogicTests.swift`.
 */
class VaultSearchLogicTest {

    // ── Sections ──

    /** Mirrors `testArticlesAndMediaGetTheirOwnSections` in VaultSearchLogicTests.swift. */
    @Test
    fun articlesAndMediaGetTheirOwnSections() {
        assertEquals(Section.ARTICLES, VaultSearchLogic.section(30023))
        for (kind in listOf(20, 21, 22, 34235, 34236)) {
            assertEquals("kind $kind", Section.MEDIA, VaultSearchLogic.section(kind))
        }
    }

    /** Mirrors `testEverythingElseIsANote` in VaultSearchLogicTests.swift. */
    @Test
    fun everythingElseIsANote() {
        for (kind in listOf(1, 1111, 9802, 1068)) {
            assertEquals("kind $kind", Section.NOTES, VaultSearchLogic.section(kind))
        }
    }

    // ── Hashtags ──

    /** Mirrors `testHashtagsComeFromTextAndTTags` in VaultSearchLogicTests.swift. */
    @Test
    fun hashtagsComeFromTextAndTTags() {
        val tags = VaultSearchLogic.hashtags(
            listOf(
                "Stacking #Bitcoin daily" to emptyList(),
                "no hashtag in the text" to listOf(listOf("t", "bitcoiners"), listOf("p", "abc")),
            ),
            "bitcoin",
        )
        assertEquals(listOf("bitcoin", "bitcoiners"), tags)
    }

    /** Mirrors `testHashtagsMustContainAQueryWord` in VaultSearchLogicTests.swift. */
    @Test
    fun hashtagsMustContainAQueryWord() {
        val tags = VaultSearchLogic.hashtags(listOf("#coffee and #bitcoin" to emptyList()), "bitcoin")
        assertEquals(listOf("bitcoin"), tags)
    }

    /** Mirrors `testHashInTheQueryIsIgnored` in VaultSearchLogicTests.swift. */
    @Test
    fun hashInTheQueryIsIgnored() {
        val tags = VaultSearchLogic.hashtags(listOf("#nostr" to emptyList()), "#nostr")
        assertEquals(listOf("nostr"), tags)
    }

    /** Mirrors `testAnyQueryWordFindsATag` in VaultSearchLogicTests.swift. */
    @Test
    fun anyQueryWordFindsATag() {
        val tags = VaultSearchLogic.hashtags(listOf("#zapcooking #grownostr" to emptyList()), "zap nostr")
        assertEquals(listOf("grownostr", "zapcooking"), tags)
    }

    /** Mirrors `testHashtagsAreDeduplicatedAcrossNotes` in VaultSearchLogicTests.swift. */
    @Test
    fun hashtagsAreDeduplicatedAcrossNotes() {
        val tags = VaultSearchLogic.hashtags(
            listOf("#Nostr" to emptyList(), "#nostr" to listOf(listOf("t", "Nostr"))),
            "nostr",
        )
        assertEquals(listOf("nostr"), tags)
    }

    // ── Links ──

    /** Mirrors `testEachURLOnceInNoteOrder` in VaultSearchLogicTests.swift. */
    @Test
    fun eachUrlOnceInNoteOrder() {
        val links = VaultSearchLogic.links(
            listOf(
                "a" to "see https://example.com/one and http://example.org",
                "b" to "again https://example.com/one",
            ),
        )
        assertEquals(listOf("https://example.com/one", "http://example.org"), links.map { it.url })
        assertEquals(listOf("a", "a"), links.map { it.noteId })
        assertEquals("example.com/one", links.firstOrNull()?.title)
    }

    /** Mirrors `testSentencePunctuationIsNotPartOfTheLink` in VaultSearchLogicTests.swift. */
    @Test
    fun sentencePunctuationIsNotPartOfTheLink() {
        val links = VaultSearchLogic.links(
            listOf("a" to "Read it (https://example.com/post), then https://example.com/two."),
        )
        assertEquals(listOf("https://example.com/post", "https://example.com/two"), links.map { it.url })
    }

    /** Mirrors `testAClosingParenTheURLOpenedStays` in VaultSearchLogicTests.swift. */
    @Test
    fun aClosingParenTheUrlOpenedStays() {
        // The Swift multi-line literal joins its lines with `\` continuations: one line of text.
        val text = "https://en.wikipedia.org/wiki/Bitcoin_(currency) and " +
            "(see https://en.wikipedia.org/wiki/Nostr_(protocol)). " +
            "[https://example.com/x[1]]"
        val links = VaultSearchLogic.links(listOf("a" to text))
        assertEquals(
            listOf(
                "https://en.wikipedia.org/wiki/Bitcoin_(currency)",
                "https://en.wikipedia.org/wiki/Nostr_(protocol)",
                "https://example.com/x[1]",
            ),
            links.map { it.url },
        )
    }

    /** Mirrors `testNoLinksInPlainText` in VaultSearchLogicTests.swift. */
    @Test
    fun noLinksInPlainText() {
        assertTrue(VaultSearchLogic.links(listOf("a" to "no links here")).isEmpty())
    }

    // ── People ──

    private val jackNpub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val jackHex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"

    /**
     * Stands in for `HavenBridge.decodeNpub` (native, not loadable in unit tests).
     * Swift checks the npub checksum inside `VaultSearchLogic`; on Android the
     * checksum check is `HavenBridge`'s job, so here only the exact npub the Swift
     * test uses decodes, and anything else (a bad checksum included) is null.
     * Callers lowercase before decoding.
     */
    private val decodeNpub: (String) -> String? = mapOf(jackNpub to jackHex)::get

    /** Mirrors `testAPastedKeyNamesItsPerson` in VaultSearchLogicTests.swift. */
    @Test
    fun aPastedKeyNamesItsPerson() {
        assertEquals(jackHex, VaultSearchLogic.pubkey(jackHex, decodeNpub))
        assertEquals(jackHex, VaultSearchLogic.pubkey(" ${jackHex.uppercase()} ", decodeNpub))
        assertEquals(jackHex, VaultSearchLogic.pubkey(jackNpub, decodeNpub))
        assertEquals(jackHex, VaultSearchLogic.pubkey("nostr:$jackNpub", decodeNpub))
        assertNull(VaultSearchLogic.pubkey(jackHex.dropLast(1), decodeNpub))
        assertNull(VaultSearchLogic.pubkey("jack", decodeNpub))
    }

    /** Mirrors `testAHexKeyFindsThatProfile` in VaultSearchLogicTests.swift. */
    @Test
    fun aHexKeyFindsThatProfile() {
        val noName = listOf<String?>(null, null, null, null)
        assertTrue(VaultSearchLogic.keepsPerson(jackHex, noName, jackHex, decodeNpub))
        assertTrue(VaultSearchLogic.keepsPerson(jackHex, noName, jackNpub, decodeNpub))
        val other = "ab".repeat(32)
        assertFalse(VaultSearchLogic.keepsPerson(other, listOf("jack", null, null, null), jackHex, decodeNpub))
    }

    /** Mirrors `testABareHexEventIdMakesNoPerson` in VaultSearchLogicTests.swift. */
    @Test
    fun aBareHexEventIdMakesNoPerson() {
        val eventId = "5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"
        assertNull(VaultSearchLogic.keyOnlyPerson(eventId, decodeNpub) { false })
        assertEquals(jackHex, VaultSearchLogic.keyOnlyPerson(jackHex, decodeNpub) { it == jackHex })
        assertEquals(jackHex, VaultSearchLogic.keyOnlyPerson(jackNpub, decodeNpub) { false })
        assertEquals(jackHex, VaultSearchLogic.keyOnlyPerson("nostr:$jackNpub", decodeNpub) { false })
    }

    /** Mirrors `testNonASCIIHexDigitsAreNotAKey` in VaultSearchLogicTests.swift. */
    @Test
    fun nonAsciiHexDigitsAreNotAKey() {
        assertNull(VaultSearchLogic.pubkey("１".repeat(64), decodeNpub))
    }

    /** Mirrors `testAShortQueryDoesNotMatchInsideTheKey` in VaultSearchLogicTests.swift. */
    @Test
    fun aShortQueryDoesNotMatchInsideTheKey() {
        assertFalse(VaultSearchLogic.keepsPerson(jackHex, listOf("Jack", "jack", null, null), "abcd", decodeNpub))
        assertTrue(VaultSearchLogic.keepsPerson(jackHex, listOf("Jack", "jack", null, null), "jack", decodeNpub))
        assertTrue(VaultSearchLogic.keepsPerson(jackHex, listOf(null, null, null, "jack@cash.app"), "cash", decodeNpub))
    }

    // ── Query state ──

    /** Mirrors `testBackToTheShownQueryDoesNotLeaveTheSpinnerUp` in VaultSearchLogicTests.swift. */
    @Test
    fun backToTheShownQueryDoesNotLeaveTheSpinnerUp() {
        val state = QueryState()
        assertEquals(QueryState.Next.Run("ab"), state.typed("ab"))
        assertTrue(state.started("ab"))
        assertTrue(state.landed("ab", Status.DONE))

        assertEquals(QueryState.Next.Run("abc"), state.typed("abc"))
        assertTrue(state.started("abc"))
        assertEquals(Status.SEARCHING, state.status)

        assertEquals(QueryState.Next.Keep, state.typed("ab"))
        assertEquals(Status.DONE, state.status)
        assertEquals("ab", state.resultsQuery)

        // "abc" finishes late: it is for a query no longer in the field.
        assertFalse(state.landed("abc", Status.DONE))
        assertEquals(Status.DONE, state.status)
        assertEquals("ab", state.resultsQuery)
    }

    /** Mirrors `testALateAnswerForAnOldQueryIsDropped` in VaultSearchLogicTests.swift. */
    @Test
    fun aLateAnswerForAnOldQueryIsDropped() {
        val state = QueryState()
        state.typed("ab"); state.started("ab")
        assertEquals(QueryState.Next.Run("abc"), state.typed("abc"))
        state.started("abc")
        assertEquals(QueryState.Next.Run("ab"), state.typed("ab"))
        state.started("ab")
        assertFalse(state.landed("abc", Status.DONE))
        assertEquals(Status.SEARCHING, state.status)
        assertTrue(state.landed("ab", Status.DONE))
        assertEquals(Status.DONE, state.status)
    }

    /** Mirrors `testAStaleSearchDoesNotStart` in VaultSearchLogicTests.swift. */
    @Test
    fun aStaleSearchDoesNotStart() {
        val state = QueryState()
        state.typed("ab")
        state.typed("abc")
        assertFalse(state.started("ab"))
        assertEquals(Status.IDLE, state.status)
    }

    /** Mirrors `testUnderTwoCharactersClears` in VaultSearchLogicTests.swift. */
    @Test
    fun underTwoCharactersClears() {
        val state = QueryState()
        state.typed("ab"); state.started("ab"); state.landed("ab", Status.DONE)
        assertEquals(QueryState.Next.Clear, state.typed(" a "))
        assertEquals(Status.IDLE, state.status)
        assertEquals("", state.resultsQuery)
    }

    /** Mirrors `testPartialAnswersAreAskedAgain` in VaultSearchLogicTests.swift. */
    @Test
    fun partialAnswersAreAskedAgain() {
        for (partial in listOf(Status.IN_MEMORY, Status.CUT_SHORT)) {
            val state = QueryState()
            state.typed("ab"); state.started("ab"); state.landed("ab", partial)
            assertEquals("$partial", QueryState.Next.Run("ab"), state.typed("ab "))
        }
    }
}

package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Articles and Recipes follow the one Following / Global / shield rule:
 * Following keeps to follows, Global to the Web of Trust (failing closed on an
 * empty graph), and Everyone to anyone.
 */
class LongFormScopeTest {
    private val friend = "f".repeat(64)
    private val trusted = "e".repeat(64)
    private val stranger = "d".repeat(64)

    private fun article(id: Char, pubkey: String, recipe: Boolean = false) = FeedNote.fromEvent(
        id = id.toString().repeat(64), pubkey = pubkey, content = "Body",
        tags = listOf(listOf("d", "x$id")) + if (recipe) listOf(listOf("t", "zapcooking")) else emptyList(),
        createdAt = 1_790_000_000, kind = 30023,
    )

    private val notes = listOf(article('1', friend), article('2', trusted), article('3', stranger))

    private fun shown(mode: FeedMode, global: Boolean, requiresTrust: Boolean, wot: Set<String>, list: List<FeedNote> = notes) =
        FeedFilterEngine.filterFeedNotes(
            notes = list, mode = mode, blocked = emptySet(), showReposts = true, showReplies = true,
            followedPubkeys = setOf(friend), wotPubkeys = wot,
            globalRequiresTrust = requiresTrust, longFormGlobal = global,
        ).map { it.pubkey }.toSet()

    @Test fun `following keeps to follows`() {
        assertEquals(setOf(friend), shown(FeedMode.ARTICLES, global = false, requiresTrust = true, wot = setOf(friend, trusted)))
    }

    @Test fun `global keeps to the web of trust`() {
        assertEquals(setOf(friend, trusted), shown(FeedMode.ARTICLES, global = true, requiresTrust = true, wot = setOf(friend, trusted)))
    }

    @Test fun `global fails closed on an empty graph`() {
        assertEquals(emptySet<String>(), shown(FeedMode.ARTICLES, global = true, requiresTrust = true, wot = emptySet()))
    }

    @Test fun `everyone shows strangers too`() {
        assertEquals(setOf(friend, trusted, stranger), shown(FeedMode.ARTICLES, global = true, requiresTrust = false, wot = emptySet()))
    }

    @Test fun `recipes follow the same rule`() {
        val recipes = listOf(article('4', friend, recipe = true), article('5', trusted, recipe = true), article('6', stranger, recipe = true))
        assertEquals(setOf(friend), shown(FeedMode.RECIPES, global = false, requiresTrust = true, wot = setOf(trusted), list = recipes))
        assertEquals(setOf(trusted), shown(FeedMode.RECIPES, global = true, requiresTrust = true, wot = setOf(trusted), list = recipes))
    }
}

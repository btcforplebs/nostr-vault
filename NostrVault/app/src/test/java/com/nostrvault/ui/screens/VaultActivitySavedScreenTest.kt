package com.nostrvault.ui.screens

import com.nostrvault.data.model.VaultActivity
import com.nostrvault.data.model.VaultMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultActivitySavedScreenTest {
    private val me = "a".repeat(64)
    private val myOther = "c".repeat(64)
    private val them = "b".repeat(64)

    private fun like(from: String, at: Long, to: String = me) =
        VaultActivity.Event("id$from$at", from, 7, at, "+", listOf(listOf("e", "x"), listOf("p", to)))

    @Test
    fun `a like from someone else after the last visit is news`() {
        assertTrue(VaultActivitySavedScreen.hasNews(listOf(like(them, 200)), VaultMode.LIKES, me, emptySet(), lastVisit = 100))
    }

    @Test
    fun `a catch-up of a like already seen is not news`() {
        assertFalse(VaultActivitySavedScreen.hasNews(listOf(like(them, 90)), VaultMode.LIKES, me, emptySet(), lastVisit = 100))
    }

    @Test
    fun `my own accounts, other accounts' tags and other lists are not news`() {
        val events = listOf(like(myOther, 200), like(me, 200), like(them, 200, to = myOther))
        assertFalse(VaultActivitySavedScreen.hasNews(events, VaultMode.LIKES, me, setOf(me, myOther), lastVisit = 100))
        assertFalse(VaultActivitySavedScreen.hasNews(listOf(like(them, 200)), VaultMode.ZAPS, me, emptySet(), lastVisit = 100))
    }

    @Test
    fun `a saved event comes back the same, pictures worked out again`() {
        val event = VaultActivity.Event(
            "id1", them, 1, 50, "look https://x.example/a.jpg", listOf(listOf("p", me)),
            VaultActivity.pictures("id1", them, 1, 50, "look https://x.example/a.jpg", listOf(listOf("p", me))),
        )
        assertEquals(event, VaultActivitySavedScreen.load(VaultActivitySavedScreen.save(event)))
    }

    @Test
    fun `seeing Vault visits every list with news`() {
        assertEquals(
            setOf(VaultMode.NOTES, VaultMode.LIKES, VaultMode.ZAPS, VaultMode.ARTICLES, VaultMode.HIGHLIGHTS),
            VaultActivitySavedScreen.visited(VaultMode.ACTIVITY).toSet(),
        )
        assertEquals(listOf(VaultMode.LIKES), VaultActivitySavedScreen.visited(VaultMode.LIKES))
    }
}

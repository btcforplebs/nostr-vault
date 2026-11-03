package com.nostrvault.ui.screens.dm

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.DMConversation
import com.nostrvault.service.DMMessage
import org.junit.Assert.assertEquals
import org.junit.Test

/** Messages search: names and message text, on the device only. */
class DMInboxSearchTest {
    private fun conv(id: String, vararg texts: String) =
        DMConversation(id, texts.mapIndexed { i, t -> DMMessage("$id-$i", t, i.toLong(), id, isFromMe = false) })

    private val alice = conv("a", "Lunch on Friday?")
    private val bob = conv("b", "see you at the BEACH")
    private val carol = conv("c")
    private val profiles = mapOf(
        "a" to FeedProfile("a", name = "alice", displayName = "Alice Smith"),
        "b" to FeedProfile("b", name = "bob", nip05 = "bob@example.com"),
    )
    private val all = listOf(alice, bob, carol)

    private fun ids(query: String) = DMInboxSearch.filter(all, query, profiles::get).map { it.id }

    @Test fun `an empty query keeps every conversation in order`() = assertEquals(listOf("a", "b", "c"), ids("  "))

    @Test fun `display name, name and nip05 match, case-insensitively`() {
        assertEquals(listOf("a"), ids("SMITH"))
        assertEquals(listOf("b"), ids("example.com"))
    }

    @Test fun `message text matches, case-insensitively`() {
        assertEquals(listOf("b"), ids("beach"))
        assertEquals(listOf("a"), ids(" friday "))
    }

    @Test fun `a person with no profile and no matching text is left out`() = assertEquals(emptyList<String>(), ids("carol"))
}

package com.nostrvault.ui.screens.dashboard

import com.nostrvault.service.NostrEvent
import org.junit.Assert.assertEquals
import org.junit.Test

/** Same rule as iOS updateDisplayData's repost de-duplication. */
class VaultRepostDedupeTest {
    private val owner = "a".repeat(64)
    private val friend = "b".repeat(64)
    private val stranger = "c".repeat(64)

    private fun note(id: String, by: String, at: Long) = NostrEvent(id, by, at, 1, emptyList(), "hi", "")
    private fun repost(id: String, by: String, target: String, at: Long) =
        NostrEvent(id, by, at, 6, listOf(listOf("e", target), listOf("p", stranger)), "", "")

    @Test
    fun `a repost of a note listed with engagement is dropped`() {
        val events = listOf(repost("r1", stranger, "mine", 30), note("mine", owner, 20))
        assertEquals(listOf("mine"), VaultRepostDedupe.apply(events, owner, emptySet()).map { it.id })
    }

    @Test
    fun `a repost of a whitelisted note is dropped`() {
        val events = listOf(repost("r1", owner, "theirs", 30), note("theirs", friend, 20))
        assertEquals(listOf("theirs"), VaultRepostDedupe.apply(events, owner, setOf(friend)).map { it.id })
    }

    @Test
    fun `reposts of an unlisted note collapse to the newest`() {
        val events = listOf(
            repost("r-new", owner, "elsewhere", 30),
            repost("r-old", stranger, "elsewhere", 10),
            repost("r-other", owner, "another", 5),
        )
        assertEquals(listOf("r-new", "r-other"), VaultRepostDedupe.apply(events, owner, emptySet()).map { it.id })
    }

    @Test
    fun `a tagged stranger's note does not hide reposts of it`() {
        val events = listOf(repost("r1", owner, "tagged", 30), note("tagged", stranger, 20))
        assertEquals(listOf("r1", "tagged"), VaultRepostDedupe.apply(events, owner, emptySet()).map { it.id })
    }
}

package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.WebGate
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Date

/** Underrated through the gate (phase 1.5, as iOS FeedFilterEngine): its web, plus a rationed few one hop out. */
class UnderratedReachTest {
    private fun pk(c: Char) = c.toString().repeat(64)
    private val me = pk('a'); private val follow = pk('b'); private val inWeb = pk('c')
    private val near = pk('d'); private val near2 = pk('e'); private val stranger = pk('f')

    private fun note(id: String, pubkey: String, at: Long, reply: Boolean = false) = FeedNote(
        id = id, pubkey = pubkey, content = "hello", createdAt = Date(at), kind = 1,
        tags = if (reply) listOf(listOf("e", "p".repeat(64), "", "reply")) else emptyList(),
    )

    private val notes = listOf(
        note("follow", follow, 6), note("web", inWeb, 5), note("near", near, 4),
        note("near-again", near, 3), note("near2-reply", near2, 2, reply = true), note("stranger", stranger, 1),
    )

    private fun shown(
        reach: WebGate.Reach,
        mode: FeedMode = FeedMode.UNDERRATED,
        web: Set<String> = setOf(me, follow, inWeb),
        loose: Set<String> = setOf(near, near2),
    ) = FeedFilterEngine.filterFeedNotes(
        notes = notes, mode = mode, blocked = emptySet(), showReposts = true, showReplies = true,
        followedPubkeys = setOf(me, follow), wotPubkeys = web, loosePubkeys = loose, reach = reach, ownPubkeys = setOf(me),
    ).map { it.id }

    @Test fun `on its web, Underrated is the web past your follows`() {
        assertEquals(listOf("web"), shown(WebGate.Reach.WEB))
    }

    @Test fun `one hop out adds one top-level post per person, never a stranger`() {
        assertEquals(listOf("web", "near"), shown(WebGate.Reach.WEB_AND_LOOSE))
    }

    @Test fun `no graph yet shows nobody, not every stranger`() {
        assertEquals(emptyList<String>(), shown(WebGate.Reach.WEB_AND_LOOSE, web = setOf(me, follow), loose = emptySet()))
    }

    @Test fun `other feeds never show one hop out`() {
        assertEquals(listOf("web"), shown(WebGate.Reach.WEB_AND_LOOSE, mode = FeedMode.DISCOVERY))
        assertEquals(listOf("follow", "web"), shown(WebGate.Reach.WEB_AND_LOOSE, mode = FeedMode.GLOBAL))
    }
}

package com.nostrvault.ui.navigation

import com.nostrvault.data.model.VaultViewMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A notification names its own event; for a like, repost or zap that event is
 * not the post. These pin which id a tap resolves to.
 */
class NotificationTargetTest {

    private val notif = "1".repeat(64)
    private val root = "2".repeat(64)
    private val post = "3".repeat(64)
    private val author = "4".repeat(64)

    @Test fun `a reaction targets its last e tag, not the thread root`() {
        // NIP-25: a like on a reply carries the root first and the liked note last.
        val tags = listOf(listOf("e", root), listOf("p", author), listOf("e", post), listOf("k", "1"))
        assertEquals(post, NotificationTarget.targetNoteId("reaction", notif, tags))
    }

    @Test fun `a repost targets the reposted note`() {
        val tags = listOf(listOf("e", post, "wss://relay.example"), listOf("p", author))
        assertEquals(post, NotificationTarget.targetNoteId("repost", notif, tags))
    }

    @Test fun `a zap targets the zapped note from the receipt`() {
        // NIP-57 receipt: p (recipient), e (zapped note), bolt11, description.
        val tags = listOf(
            listOf("p", author),
            listOf("e", post),
            listOf("bolt11", "lnbc10n1..."),
            listOf("description", "{\"kind\":9734}"),
        )
        assertEquals(post, NotificationTarget.targetNoteId("zap", notif, tags))
    }

    @Test fun `a profile zap has no post to land on`() {
        val tags = listOf(listOf("p", author), listOf("bolt11", "lnbc10n1..."))
        assertNull(NotificationTarget.targetNoteId("zap", notif, tags))
    }

    @Test fun `an unknown reaction event never falls back to its own id`() {
        // Opening a kind 7 id as a note shows nothing; null means "do not open".
        assertNull(NotificationTarget.targetNoteId("reaction", notif, emptyList()))
    }

    @Test fun `mentions replies and quotes are the post themselves`() {
        val replyTags = listOf(listOf("e", root, "", "root"), listOf("p", author))
        for (type in listOf("mention", "reply", "quote")) {
            assertEquals(type, notif, NotificationTarget.targetNoteId(type, notif, replyTags))
        }
    }

    @Test fun `malformed e tags are skipped`() {
        val tags = listOf(listOf("e", post), listOf("e", "not-hex"), listOf("e"))
        assertEquals(post, NotificationTarget.targetNoteId("reaction", notif, tags))
    }

    @Test fun `focus candidates look for the event itself, then its targets last first`() {
        val tags = listOf(listOf("e", root), listOf("e", post))
        assertEquals(listOf(notif, post, root), NotificationTarget.focusCandidates(notif, tags))
        assertEquals(listOf(notif), NotificationTarget.focusCandidates(notif, emptyList()))
    }

    @Test fun `each type opens the list that holds it`() {
        assertEquals(VaultViewMode.LIKES, NotificationTarget.viewFor("reaction", zapsOnly = false))
        assertEquals(VaultViewMode.NOTES, NotificationTarget.viewFor("reaction", zapsOnly = true))
        assertEquals(VaultViewMode.ZAPS, NotificationTarget.viewFor("zap", zapsOnly = false))
        for (type in listOf("mention", "reply", "quote", "repost")) {
            assertEquals(type, VaultViewMode.NOTES, NotificationTarget.viewFor(type, zapsOnly = false))
        }
    }

    @Test fun `a parked focus is handed out once`() {
        RelayFocus.request(RelayFocusRequest("zap", notif))
        assertEquals(RelayFocusRequest("zap", notif), RelayFocus.consume())
        assertNull(RelayFocus.consume())
    }
}

package com.nostrvault.service

import com.nostrvault.data.model.FeedProfile
import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationPreviewMentionTest {
    private val npub = "npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx"
    private val hex = "61bf790b2094afb03495c9e136acf615be0fccc2cb95b5acfb5f6ccefe18b062"
    private val profiles = mapOf(hex to FeedProfile(pubkey = hex, name = "Logen"))

    @Test
    fun `a mention shows the name, not the npub`() {
        assertEquals(
            "hey @Logen look at this",
            LocalNotificationService.notePreview("mention", "hey nostr:$npub look at this", profiles),
        )
        assertEquals(
            "@Logen agreed",
            LocalNotificationService.notePreview("reply", "nostr:$npub agreed", profiles),
        )
    }

    @Test
    fun `an unknown profile shows a short key, never the raw nostr link`() {
        assertEquals(
            "hey @61bf790b…",
            LocalNotificationService.notePreview("mention", "hey nostr:$npub", emptyMap()),
        )
    }

    @Test
    fun `a reaction keeps its emoji`() {
        assertEquals("🤙", LocalNotificationService.notePreview("reaction", "🤙", profiles))
    }
}

package com.nostrvault.service

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** Which sound a config picks, and which channels a pick creates and retires. */
class NotificationSoundTest {

    @Test
    fun `a fresh config picks Chime, as iOS does`() {
        assertEquals(NotificationSound.CHIME, NotificationSound.fromName(HavenConfig().notificationSoundName))
    }

    @Test
    fun `names round-trip and unknown ones fall back to the default`() {
        for (sound in NotificationSound.entries) assertEquals(sound, NotificationSound.fromName(sound.displayName))
        assertEquals(NotificationSound.DEFAULT, NotificationSound.fromName("notification"))
        assertEquals(NotificationSound.DEFAULT, NotificationSound.fromName(null))
    }

    @Test
    fun `each sound has its own channel and raw resource`() {
        assertEquals("nostrvault_events_ping", NotificationSound.PING.channelId)
        assertEquals(NotificationSound.entries.size, NotificationSound.entries.map { it.channelId }.toSet().size)
        assertEquals(NotificationSound.entries.size, NotificationSound.entries.map { it.resId }.toSet().size)
    }

    @Test
    fun `a pick retires every other events channel but its own`() {
        val retired = NotificationSound.retiredChannelIds(NotificationSound.PING)
        assertFalse(NotificationSound.PING.channelId in retired)
        assertEquals(
            listOf(
                "nostrvault_events_chime", "nostrvault_events_confident", "nostrvault_events_juntos",
                "nostrvault_events_v2", "nostrvault_events",
            ),
            retired,
        )
    }

    @Test
    fun `an upgrade copies the old v2 channel's settings`() {
        assertEquals(
            "nostrvault_events_v2",
            NotificationSound.settingsSource(NotificationSound.CHIME, setOf("nostrvault_relay", "nostrvault_events_v2")),
        )
    }

    @Test
    fun `a change of sound copies the channel it replaces`() {
        assertEquals(
            "nostrvault_events_chime",
            NotificationSound.settingsSource(NotificationSound.PING, setOf("nostrvault_events_chime", "nostrvault_relay")),
        )
    }

    @Test
    fun `a fresh install has nothing to copy`() {
        assertNull(NotificationSound.settingsSource(NotificationSound.CHIME, setOf("nostrvault_relay")))
    }
}

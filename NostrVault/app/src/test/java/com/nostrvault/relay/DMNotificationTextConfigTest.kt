package com.nostrvault.relay

import com.nostrvault.service.LocalNotificationService
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** DM notifications hide the message text by default (Logen, 2026-11-12); a saved choice is kept. iOS DMNotificationTextTests. */
class DMNotificationTextConfigTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `hidden by default`() {
        assertFalse(HavenConfig().showDMTextInNotifications)
        assertEquals("", LocalNotificationService.dmNotificationText("meet at 6", showsText = false))
    }

    @Test
    fun `shown when turned on`() {
        assertEquals("meet at 6", LocalNotificationService.dmNotificationText("meet  at\n6", showsText = true))
    }

    @Test
    fun `a config saved before the setting existed hides text`() {
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertFalse(old.showDMTextInNotifications)
    }

    @Test
    fun `a saved choice survives a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig(showDMTextInNotifications = true))
        assertTrue(json.decodeFromString(HavenConfig.serializer(), saved).showDMTextInNotifications)
    }
}

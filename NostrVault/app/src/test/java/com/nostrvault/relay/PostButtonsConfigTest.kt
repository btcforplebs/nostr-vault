package com.nostrvault.relay

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Appearance → Post buttons (iOS `postButtons`): ⚡️ puts a zap button on
 * posts. Android has always shown it, so installs that never touched the
 * setting keep it.
 */
class PostButtonsConfigTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `a config saved before the setting existed keeps the zap button`() {
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertTrue(HavenConfig.postButtonsShowZap(old.postButtons))
    }

    @Test
    fun `a new install shows the zap button`() {
        assertTrue(HavenConfig.postButtonsShowZap(HavenConfig.newInstall().postButtons))
    }

    @Test
    fun `taking the bolt out survives a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig(postButtons = ""))
        val loaded = json.decodeFromString(HavenConfig.serializer(), saved)
        assertEquals("", loaded.postButtons)
        assertFalse(HavenConfig.postButtonsShowZap(loaded.postButtons))
    }

    @Test
    fun `only the bolt is read, with or without the emoji variation selector`() {
        assertTrue(HavenConfig.postButtonsShowZap("⚡️"))
        assertTrue(HavenConfig.postButtonsShowZap("⚡"))
        assertTrue(HavenConfig.postButtonsShowZap("🔥⚡️"))
        assertFalse(HavenConfig.postButtonsShowZap(""))
        assertFalse(HavenConfig.postButtonsShowZap("🔥❤️"))
    }
}

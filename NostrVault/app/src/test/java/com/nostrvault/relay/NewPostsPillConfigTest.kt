package com.nostrvault.relay

import kotlinx.serialization.json.Json
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Appearance's "New Posts Pill" switch: on unless the user turns it off (iOS #276). */
class NewPostsPillConfigTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `defaults to shown`() {
        assertTrue(HavenConfig().showNewPostsPill)
    }

    @Test
    fun `a config saved before the setting existed keeps the pill`() {
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertTrue(old.showNewPostsPill)
    }

    @Test
    fun `off survives a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig(showNewPostsPill = false))
        assertFalse(json.decodeFromString(HavenConfig.serializer(), saved).showNewPostsPill)
    }
}

package com.nostrvault.relay

import kotlinx.serialization.json.Json
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Auto-load is a saved setting, off unless the user turns it on (iOS parity). */
class AutoLoadNewPostsConfigTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `defaults to off`() {
        assertFalse(HavenConfig().autoLoadNewPosts)
    }

    @Test
    fun `a config saved before the setting existed decodes as off`() {
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertFalse(old.autoLoadNewPosts)
    }

    @Test
    fun `survives a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig(autoLoadNewPosts = true))
        assertTrue(json.decodeFromString(HavenConfig.serializer(), saved).autoLoadNewPosts)
    }
}

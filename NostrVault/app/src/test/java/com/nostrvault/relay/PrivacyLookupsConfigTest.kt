package com.nostrvault.relay

import kotlinx.serialization.json.Json
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Vertex and Fanfares lookups are signed by your key, so they stay off until Settings > Privacy turns them on (iOS parity). */
class PrivacyLookupsConfigTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `default to off`() {
        assertFalse(HavenConfig().vertexLookups)
        assertFalse(HavenConfig().fanfaresAutoCheck)
    }

    @Test
    fun `a config saved before the settings existed decodes as off`() {
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertFalse(old.vertexLookups)
        assertFalse(old.fanfaresAutoCheck)
    }

    @Test
    fun `survive a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig(vertexLookups = true, fanfaresAutoCheck = true))
        val loaded = json.decodeFromString(HavenConfig.serializer(), saved)
        assertTrue(loaded.vertexLookups)
        assertTrue(loaded.fanfaresAutoCheck)
    }
}

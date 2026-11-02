package com.nostrvault.relay

import kotlinx.serialization.json.Json
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Appearance's "Hide Nostr Vault logo on posts" switch: off (logo shows) until the user turns it on. */
class HideNostrVaultBadgeConfigTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `defaults to showing the logo`() {
        assertFalse(HavenConfig().hideNostrVaultBadge)
    }

    @Test
    fun `a config saved before the setting existed keeps the logo`() {
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner"}""")
        assertFalse(old.hideNostrVaultBadge)
    }

    @Test
    fun `hidden survives a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig(hideNostrVaultBadge = true))
        assertTrue(json.decodeFromString(HavenConfig.serializer(), saved).hideNostrVaultBadge)
    }
}

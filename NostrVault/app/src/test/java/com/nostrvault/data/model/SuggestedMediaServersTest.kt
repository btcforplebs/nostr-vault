package com.nostrvault.data.model

import com.nostrvault.relay.blossomUploadServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Media Servers › Suggested hides a server once the user has it, however they
 * typed it, and never offers one the app would skip. Mirrors iOS
 * SuggestedMediaServersTests.
 */
class SuggestedMediaServersTest {

    @Test
    fun emptyListShowsEverySuggestion() {
        assertEquals(SuggestedMediaServers.all, SuggestedMediaServers.notYetAdded(emptyList()))
    }

    @Test
    fun addedServerIsHiddenEvenWithSlashOrCase() {
        val left = SuggestedMediaServers.notYetAdded(listOf("https://Blossom.Primal.net/"))
        assertFalse(left.map { it.host }.contains("blossom.primal.net"))
        assertEquals(SuggestedMediaServers.all.size - 1, left.size)
    }

    /** The app uploads a typed nostr.build address to blossom.nostr.build. */
    @Test
    fun typedNostrBuildHidesBlossomNostrBuild() {
        val left = SuggestedMediaServers.notYetAdded(listOf("https://nostr.build"))
        assertFalse(left.map { it.host }.contains("blossom.nostr.build"))
    }

    @Test
    fun otherServersDoNotHideSuggestions() {
        val left = SuggestedMediaServers.notYetAdded(listOf("https://cdn.example.com", "https://nostr.band"))
        assertEquals(SuggestedMediaServers.all, left)
    }

    @Test
    fun everySuggestionIsAnHttpsServerTheAppUploadsTo() {
        assertTrue(SuggestedMediaServers.all.isNotEmpty())
        val defunct = listOf("blossom.kylezien.com", "cdn.satellite.earth")
        for (server in SuggestedMediaServers.all) {
            assertTrue(server.url, server.url.startsWith("https://"))
            assertFalse(server.url, server.url.endsWith("/"))
            assertEquals(server.url, blossomUploadServer(server.url))
            assertFalse(server.url, server.host in defunct)
            assertTrue(server.url, server.note.isNotEmpty())
        }
        assertEquals(SuggestedMediaServers.all.size, SuggestedMediaServers.all.map { it.host }.toSet().size)
    }

    /** Same list as iOS SuggestedMediaServers.swift; a change there must land here too. */
    @Test
    fun matchesTheIosList() {
        assertEquals(
            listOf("blossom.primal.net", "blossom.nostr.build", "nostr.media", "blossom.azzamo.media", "blossom.jumble.social", "nostrmedia.com"),
            SuggestedMediaServers.all.map { it.host },
        )
    }
}

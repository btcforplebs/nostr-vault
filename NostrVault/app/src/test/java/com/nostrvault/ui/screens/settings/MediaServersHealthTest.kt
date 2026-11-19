package com.nostrvault.ui.screens.settings

import com.nostrvault.service.BlobPresence
import com.nostrvault.ui.screens.dashboard.MediaServer
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/** Media Servers health and copy, one page as on iPhone (#1986): server states, words, and which row shows what. */
class MediaServersHealthTest {

    @Test
    fun `a test against a file the server held decides its state`() {
        assertEquals(MediaServer.Health.WORKING, MediaServer.Health.fromTest(BlobPresence.PRESENT, answered = true))
        assertEquals(MediaServer.Health.LOST_FILE, MediaServer.Health.fromTest(BlobPresence.ABSENT, answered = true))
        assertEquals(MediaServer.Health.OFFLINE, MediaServer.Health.fromTest(BlobPresence.UNREACHABLE, answered = true))
    }

    /** Answering is not green: a web server that is not Blossom answers too. */
    @Test
    fun `with no file to ask for, answering is all it can show`() {
        assertEquals(MediaServer.Health.ANSWERS, MediaServer.Health.fromTest(null, answered = true))
        assertEquals(MediaServer.Health.OFFLINE, MediaServer.Health.fromTest(null, answered = false))
    }

    @Test
    fun `status lines read like the iPhone`() {
        val s = MediaServer("https://a.example", "a.example")
        assertEquals("Not checked yet", serverStatusLine(s, now = 0))
        assertEquals("Checking…", serverStatusLine(s.copy(health = MediaServer.Health.CHECKING, checkedAtMillis = 1), now = 2))
        assertEquals("Has your files", serverStatusLine(s.copy(health = MediaServer.Health.WORKING), now = 0))
        assertEquals(
            "Answers, but a file it had is gone · checked just now",
            serverStatusLine(s.copy(health = MediaServer.Health.LOST_FILE, checkedAtMillis = 10_000), now = 40_000),
        )
        assertEquals(
            "Not answering · checked just now",
            serverStatusLine(s.copy(health = MediaServer.Health.OFFLINE, checkedAtMillis = 0), now = 59_999),
        )
    }

    @Test
    fun `a listed server shows the health of the address uploads use`() {
        val checked = MediaServer("https://blossom.nostr.build", "blossom.nostr.build", MediaServer.Health.WORKING)
        val saved = listOf("https://nostr.build", "https://b.example")
        // nostr.build's website uploads go to blossom.nostr.build, so that is what was checked.
        assertEquals(checked to "Not checked yet", MediaServersHealth.lookup("https://nostr.build", saved, listOf(checked)))
        assertEquals(null to "Not checked yet", MediaServersHealth.lookup("https://b.example", saved, listOf(checked)))
    }

    @Test
    fun `an unsaved or retired server says so instead of a dot`() {
        assertEquals(null to "Not saved yet", MediaServersHealth.lookup("https://new.example", listOf("https://b.example"), emptyList()))
        assertEquals(
            null to "Not used: this server is gone",
            MediaServersHealth.lookup("https://nostr.band", listOf("https://nostr.band"), emptyList()),
        )
    }

    /** One home each (RESEARCH/NV_VAULT_SETTINGS_DUPLICATES_2026_11_19.md): Advanced keeps Relay details and Raw logs only. */
    @Test
    fun `the dashboard's Advanced no longer repeats Media servers or Mesh`() {
        val content = source("ui/screens/dashboard/VaultDashboardContent.kt")
        val advanced = content.substringAfter("// ── Advanced")
        assertTrue(advanced.contains("\"Relay details\""))
        assertTrue(advanced.contains("\"Raw logs\""))
        assertFalse(advanced.contains("\"Media servers\""))
        assertFalse(advanced.contains("\"Mesh settings\""))
        assertFalse(File(root, "ui/screens/dashboard/MediaServersPage.kt").exists())
    }

    /** Import is the dashboard's one button; this page keeps Auto-Mirror and Copy to servers (iOS BlossomSettingsView). */
    @Test
    fun `Media Servers has the copy section and no Mirror Now`() {
        val page = source("ui/screens/settings/BlossomSettingsScreen.kt")
        assertTrue(page.contains("YourMediaSection(health)"))
        assertTrue(page.contains("ServerHealthLine("))
        assertFalse(page.contains("Mirror Now"))
        assertEquals("To import now, use Import media on the dashboard.", OFFLINE_COPIES_FOOTER)
    }

    private val root = File("src/main/java/com/nostrvault")
    private fun source(path: String) = File(root, path).readText()
}

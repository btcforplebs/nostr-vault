package com.nostrvault.ui.screens.dashboard

import com.nostrvault.service.BlobPresence
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Media servers page's server states and words, as on iPhone (MediaServersPage). */
class MediaServersPageTest {

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
}

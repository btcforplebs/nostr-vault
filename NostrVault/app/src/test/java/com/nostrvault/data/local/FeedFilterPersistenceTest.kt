package com.nostrvault.data.local

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The feed's Reposts and Replies switches must survive a restart (#412). They
 * used to live only in FeedService memory, so every launch turned both back on.
 */
class FeedFilterPersistenceTest {

    private val filesDir: File = Files.createTempDirectory("config-store").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@FeedFilterPersistenceTest.filesDir }
    private val configFile = File(filesDir, "nostrvault_config.json")

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    @Test
    fun `switched-off reposts and replies are still off after a reload`() = runBlocking {
        val before = ConfigStore(context).apply { reload() }
        before.updateAsync { it.copy(showReposts = false, showReplies = false) }

        // A new store is what the next launch sees: nothing but the file on disk.
        val after = ConfigStore(context).apply { reload() }
        assertFalse(after.config.value.showReposts)
        assertFalse(after.config.value.showReplies)
    }

    @Test
    fun `saved switches use the iOS keys and survive a save by this build`() = runBlocking {
        // The shape iOS HavenConfig writes. A build without these fields drops
        // them on load, so the next save erases them.
        configFile.writeText("""{"showReposts": false, "showReplies": false}""")

        val store = ConfigStore(context).apply { reload() }
        store.updateAsync { it }

        val saved = configFile.readText()
        assertTrue(saved, Regex(""""showReposts"\s*:\s*false""").containsMatchIn(saved))
        assertTrue(saved, Regex(""""showReplies"\s*:\s*false""").containsMatchIn(saved))
    }
}

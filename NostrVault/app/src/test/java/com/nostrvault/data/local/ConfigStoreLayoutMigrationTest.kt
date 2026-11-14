package com.nostrvault.data.local

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Compact View is gone (2026-11-11): a saved "condensed" feed loads as expanded with replies off, once. */
class ConfigStoreLayoutMigrationTest {

    private val filesDir: File = Files.createTempDirectory("config-layout").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@ConfigStoreLayoutMigrationTest.filesDir }
    private val configFile = File(filesDir, "nostrvault_config.json")

    private object NoKeys : ConfigStore.KeyVault {
        override fun read(hexPubkey: String): String? = null
        override fun write(hexKey: String, hexPubkey: String) = true
        override fun forgetOwner(hexPubkey: String?, npub: String) {}
        override fun forgetEverything() {}
    }

    private fun store() = ConfigStore(context).apply {
        keyVault = NoKeys
        clearPrefs = {}
        wipeOutsideFiles = {}
        reload()
    }

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    @Test
    fun `a condensed feed loads expanded, keeps replies on, and the file is rewritten`() {
        configFile.writeText("""{"feedLayoutModes":{"FOLLOWING":"condensed","GLOBAL":"threaded"},"showReplies":true,"repliesBackOnV1":true}""")

        val config = store().config.value
        assertEquals(mapOf("FOLLOWING" to "expanded", "GLOBAL" to "threaded"), config.feedLayoutModes)
        // A copied settings file can bring "condensed" back on every launch (11/14), so it no longer turns replies off.
        assertTrue(config.showReplies)

        val deadline = System.currentTimeMillis() + 5_000
        while (configFile.readText().contains("condensed") && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertFalse(configFile.readText().contains("condensed"))
    }

    @Test
    fun `replies left off by the condensed loop come back on once`() {
        configFile.writeText("""{"feedLayoutModes":{"GLOBAL":"threaded"},"showReplies":false}""")
        assertTrue(store().config.value.showReplies)

        val deadline = System.currentTimeMillis() + 5_000
        while (!configFile.readText().contains("repliesBackOnV1") && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertTrue(Regex(""""repliesBackOnV1"\s*:\s*true""").containsMatchIn(configFile.readText()))
    }

    @Test
    fun `after the one time reset, replies turned off stay off`() {
        configFile.writeText("""{"feedLayoutModes":{"GLOBAL":"threaded"},"showReplies":false,"repliesBackOnV1":true}""")
        assertFalse(store().config.value.showReplies)
    }

    @Test
    fun `a config with no condensed feed keeps its replies setting`() {
        configFile.writeText("""{"feedLayoutModes":{"FOLLOWING":"expanded","GLOBAL":"threaded"},"showReplies":true}""")
        assertTrue(store().config.value.showReplies)
    }
}

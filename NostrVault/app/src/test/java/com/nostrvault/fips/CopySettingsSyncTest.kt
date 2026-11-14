package com.nostrvault.fips

import com.nostrvault.fips.CopySettingsSync.Step
import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Settings stay synced (pick 1): when this device writes the file and when it applies one the engine left. */
class CopySettingsSyncTest {
    private val now = 1767000300L
    private val mine = CopySettings.keys(HavenConfig(zapsOnlyMode = false))
    private val theirs = CopySettings.keys(HavenConfig(zapsOnlyMode = true))

    @Test
    fun `no file yet, setup done - the first file is dated 1, so a linked device's real change wins`() {
        assertEquals(Step.Write(1), CopySettingsSync.step(mine, null, null, 0, now, setupDone = true))
    }

    @Test
    fun `no file and setup not done - nothing is written, so a fresh device never overwrites A`() {
        assertEquals(Step.Nothing, CopySettingsSync.step(mine, null, null, 0, now, setupDone = false))
        // Not even over a refused file, and not for a change made during setup.
        val secret = """{"v":1,"updated_at":50,"keys":{"dm_relays":["nsec1${"q".repeat(58)}"]}}"""
        assertEquals(Step.Nothing, CopySettingsSync.step(mine, secret, null, 0, now, setupDone = false))
        val ownFile = CopySettings.file(theirs, 100)
        assertEquals(Step.Nothing, CopySettingsSync.step(mine, ownFile, theirs.toString(), 100, now, setupDone = false))
    }

    @Test
    fun `during setup the copy's settings are still applied`() {
        val file = CopySettings.file(theirs, 50)
        assertTrue(CopySettingsSync.step(mine, file, null, 0, now, setupDone = false) is Step.Apply)
    }

    @Test
    fun `the first file passes the engine's check`() {
        val first = CopySettings.file(mine, CopySettingsSync.FIRST_FILE_AT)
        assertEquals(1L, CopySettings.check(first, now).first?.updatedAt)
    }

    @Test
    fun `a change here since the last write is written`() {
        val file = CopySettings.file(theirs, 100)
        assertEquals(Step.Write(now), CopySettingsSync.step(mine, file, theirs.toString(), 100, now, setupDone = true))
    }

    @Test
    fun `the file this device wrote, unchanged since, is left alone`() {
        val file = CopySettings.file(mine, 100)
        assertEquals(Step.Nothing, CopySettingsSync.step(mine, file, mine.toString(), 100, now, setupDone = true))
    }

    @Test
    fun `a file the engine left from the other device is applied`() {
        val file = CopySettings.file(theirs, 50)
        val s = CopySettingsSync.step(mine, file, mine.toString(), 100, now, setupDone = true)
        assertTrue(s is Step.Apply)
        assertEquals(theirs, (s as Step.Apply).file.keys)
        // A new phone (no baseline yet) takes the copy's settings too.
        assertTrue(CopySettingsSync.step(mine, file, null, 0, now, setupDone = true) is Step.Apply)
    }

    @Test
    fun `a refused file is never applied, and is written over`() {
        val secret = """{"v":1,"updated_at":50,"keys":{"dm_relays":["nsec1${"q".repeat(58)}"]}}"""
        assertEquals(Step.Write(now), CopySettingsSync.step(mine, secret, mine.toString(), 100, now, setupDone = true))
    }

    @Test
    fun `a file with the retired condensed layout is applied and written over clean`() {
        val old = HavenConfig(feedLayoutModes = mapOf("Music" to "condensed"), zapsOnlyMode = true)
        val raw = CopySettings.file(CopySettings.keys(old).let {
            kotlinx.serialization.json.JsonObject(it + ("feed_layouts" to kotlinx.serialization.json.JsonObject(mapOf("Music" to kotlinx.serialization.json.JsonPrimitive("condensed")))))
        }, 50)
        val s = CopySettingsSync.step(mine, raw, mine.toString(), 100, now, setupDone = true)
        assertTrue(s is Step.Apply)
        assertEquals(now, (s as Step.Apply).rewriteAt)
        // Not during setup: nothing is written then.
        assertEquals(null, (CopySettingsSync.step(mine, raw, null, 0, now, setupDone = false) as Step.Apply).rewriteAt)
        // A clean foreign file is only applied.
        assertEquals(null, (CopySettingsSync.step(mine, CopySettings.file(theirs, 50), mine.toString(), 100, now, setupDone = true) as Step.Apply).rewriteAt)
    }
}


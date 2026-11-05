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
    fun `no file yet is written, so a first copy carries this device's settings`() {
        assertEquals(Step.Write, CopySettingsSync.step(mine, null, null, 0, now))
    }

    @Test
    fun `a change here since the last write is written`() {
        val file = CopySettings.file(theirs, 100)
        assertEquals(Step.Write, CopySettingsSync.step(mine, file, theirs.toString(), 100, now))
    }

    @Test
    fun `the file this device wrote, unchanged since, is left alone`() {
        val file = CopySettings.file(mine, 100)
        assertEquals(Step.Nothing, CopySettingsSync.step(mine, file, mine.toString(), 100, now))
    }

    @Test
    fun `a file the engine left from the other device is applied`() {
        val file = CopySettings.file(theirs, 50)
        val s = CopySettingsSync.step(mine, file, mine.toString(), 100, now)
        assertTrue(s is Step.Apply)
        assertEquals(theirs, (s as Step.Apply).file.keys)
        // A new phone (no baseline yet) takes the copy's settings too.
        assertTrue(CopySettingsSync.step(mine, file, null, 0, now) is Step.Apply)
    }

    @Test
    fun `a refused file is never applied, and is written over`() {
        val secret = """{"v":1,"updated_at":50,"keys":{"dm_relays":["nsec1${"q".repeat(58)}"]}}"""
        assertEquals(Step.Write, CopySettingsSync.step(mine, secret, mine.toString(), 100, now))
    }
}

package com.nostrvault.relay

import com.nostrvault.data.remote.isDamus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** relay.damus.io is out of the import-seed default (an untouched old import list loses it once) but stays a DM default. */
class DamusDefaultsTest {
    @Test
    fun `damus is out of the import seed`() {
        assertTrue(HavenConfig().importSeedRelays.none(::isDamus))
    }

    @Test
    fun `damus stays a default DM server, so an unsaved default list keeps reading it`() {
        // config.json leaves out a dmRelays equal to the default, so an
        // upgrader's list is whatever this default is now.
        assertTrue(HavenConfig.DEFAULT_DM_RELAYS.any(::isDamus))
        assertTrue(HavenConfig().dmRelays.any(::isDamus))
    }

    @Test
    fun `the old default import list becomes the new one, once`() {
        val old = HavenConfig().copy(importSeedRelays = DamusDefaults.OLD_IMPORT_SEED)
        val marker = Files.createTempDirectory("damus").resolve("done").toFile()
        assertEquals(HavenConfig().importSeedRelays, DamusDefaults.droppingOnce(old, marker).importSeedRelays)
        assertTrue(marker.exists())
        assertSame(old, DamusDefaults.droppingOnce(old, marker))
        marker.parentFile.deleteRecursively()
    }

    @Test
    fun `an edited import list and a saved DM list keep damus`() {
        val edited = HavenConfig().copy(
            importSeedRelays = listOf("wss://relay.damus.io", "wss://my.relay"),
            dmRelays = listOf("wss://relay.damus.io"),
        )
        assertSame(edited, DamusDefaults.dropping(edited))
    }
}

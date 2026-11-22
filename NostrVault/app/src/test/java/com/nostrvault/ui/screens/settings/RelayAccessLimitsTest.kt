package com.nostrvault.ui.screens.settings

import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayConfiguration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Who Can Reach You only offers settings the relay actually uses (iOS RelayAccessLimitsTests). */
class RelayAccessLimitsTest {

    /** The highest Web of Trust level haven-go runs, from its own error text. */
    private fun relayMaxWotLevel(): Int {
        val wot = File("../../haven-go/pkg/wot/simple_in_memory.go").readText()
        val match = Regex("""must be between 0 and (\d+)""").find(wot)
        assertTrue("haven-go WoT level text not found; the check can't fail", match != null)
        return match!!.groupValues[1].toInt()
    }

    @Test
    fun followDistanceStopsWhereTheRelayStops() {
        assertEquals(relayMaxWotLevel(), RelayAccessLimits.FOLLOW_DISTANCE.last)
        assertEquals(1, RelayAccessLimits.FOLLOW_DISTANCE.first)
    }

    /**
     * The relay runs level 0 as a public relay. A stored 0 (or anything out of
     * range) must reach it as the level the screen shows, never raw.
     */
    @Test
    fun relayNeverGetsALevelTheScreenCannotShow() {
        for ((stored, sent) in listOf(0 to "1", -1 to "1", 1 to "1", 2 to "2", 3 to "3", 5 to "3")) {
            val env = RelayConfiguration.generateEnvDictionary(HavenConfig(chatRelayWotDepth = stored), File("/tmp/x"))
            assertEquals("stored $stored", sent, env["WOT_DEPTH"])
            assertEquals("stored $stored", sent, env["CHAT_RELAY_WOT_DEPTH"])
        }
    }

    @Test
    fun olderSavedDistanceShowsAsWhatTheRelayUses() {
        assertEquals(3, RelayAccessLimits.clampedFollowDistance(5))
        assertEquals(3, RelayAccessLimits.clampedFollowDistance(4))
        assertEquals(2, RelayAccessLimits.clampedFollowDistance(2))
        assertEquals(1, RelayAccessLimits.clampedFollowDistance(0))
    }

    /** The old Rate Limits rows edited values haven-go never read (OUTBOX_MAX_*_PER_MINUTE). */
    @Test
    fun screenEditsNoSettingTheRelayIgnores() {
        val screen = File("src/main/java/com/nostrvault/ui/screens/settings/RelayAccessSettingsScreen.kt").readText()
        assertTrue("screen source not found", screen.contains("Follow Distance"))
        for (field in listOf("outboxMaxEventsPerMinute", "outboxMaxConnectionsPerMinute")) {
            assertFalse("$field is on the screen", screen.contains("config.$field"))
        }
    }
}

package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset
import java.time.ZonedDateTime

/**
 * Zombies in your web: decoding the vault's answer, keeping the list to
 * people still followed, and the words. Mirrors iOS `WotZombiesTests`.
 * Read-only: nothing here unfollows.
 */
class WotZombiesTest {
    private val me = "a".repeat(64)
    private fun pk(c: Char) = c.toString().repeat(64)

    /** The shape haven-go's ZombieState marshals to, extra fields included. */
    private val json = """
        {"checking":false,"report":{"owner":"$me","follows":5,"fresh":1,"rotting":1,"ancient":2,
        "zombies":[
          {"pubkey":"${pk('1')}","last_seen":0,"kind":0,"days":365,"bucket":"ancient"},
          {"pubkey":"${pk('2')}","last_seen":1700000000,"kind":3,"floor":true,"days":400,"bucket":"ancient"},
          {"pubkey":"${pk('3')}","last_seen":1760000000,"kind":1,"days":200,"bucket":"rotting"},
          {"pubkey":"${pk('4')}","last_seen":1780000000,"kind":30443,"days":95,"bucket":"fresh"}],
        "checked_at":1793534400,"took_ms":40000}}
    """.trimIndent()

    @Test fun decodesTheVaultsReport() {
        val state = WotZombies.parse(json)!!
        assertFalse(state.checking)
        val report = state.report!!
        assertEquals(me, report.owner)
        assertEquals(5, report.follows)
        assertEquals(
            listOf(WotZombies.Bucket.ANCIENT, WotZombies.Bucket.ANCIENT, WotZombies.Bucket.ROTTING, WotZombies.Bucket.FRESH),
            report.zombies.map { it.bucket },
        )
        assertEquals(2, report.count(WotZombies.Bucket.ANCIENT))
        assertEquals(1, report.count(WotZombies.Bucket.ROTTING))
        assertEquals(1, report.count(WotZombies.Bucket.FRESH))
        assertEquals(1_700_000_000L, report.zombies[1].lastSeen)
    }

    @Test fun decodesCheckingAndErrors() {
        val checking = WotZombies.parse("""{"checking":true}""")!!
        assertTrue(checking.checking)
        assertNull(checking.report)
        val error = WotZombies.parse("""{"error":"relay not running"}""")!!
        assertEquals("relay not running", error.error)
        assertFalse(error.checking)
        assertNull(WotZombies.parse("not json"))
        assertNull(WotZombies.parse(null))
    }

    /** An unknown bucket from a newer vault fails the parse rather than mislabelling someone. */
    @Test fun unknownBucketIsNotGuessed() {
        assertNull(WotZombies.parse(json.replace("\"fresh\"}", "\"mummified\"}")))
    }

    /** Someone unfollowed since the check leaves the list and the counts at once. */
    @Test fun keepingOnlyPeopleStillFollowed() {
        val report = WotZombies.parse(json)!!.report!!
        val kept = report.keeping(setOf(pk('2'), pk('4'), pk('9')))
        assertEquals(listOf(pk('2'), pk('4')), kept.zombies.map { it.pubkey })
        assertEquals(3, kept.follows)
        assertEquals(1, kept.count(WotZombies.Bucket.ANCIENT))
        assertEquals(0, kept.count(WotZombies.Bucket.ROTTING))
    }

    @Test fun words() {
        assertEquals("65 of your 1,053 follows have been quiet 90+ days", WotZombies.headline(65, 1053))
        assertEquals("1 of your 10 follows has been quiet 90+ days", WotZombies.headline(1, 10))
        assertEquals("None of your 10 follows have been quiet 90+ days", WotZombies.headline(0, 10))
        assertEquals("65 quiet 90+ days, longest first", WotZombies.listHeader(65))
        assertEquals("https://plebsvszombies.cc", WotZombies.PLEBS_VS_ZOMBIES_URL)
        assertEquals(listOf("90+ days", "180+ days", "365+ days"), WotZombies.Bucket.entries.map { it.daysText })
    }

    @Test fun lastSeenText() {
        val now = ZonedDateTime.ofInstant(java.time.Instant.ofEpochSecond(1_793_534_400), ZoneOffset.UTC)
        fun text(then: ZonedDateTime) = WotZombies.lastSeenText(then.toEpochSecond(), now.toEpochSecond(), ZoneOffset.UTC)
        assertEquals("Last seen 2 yr 6 mo ago", text(now.minusYears(2).minusMonths(6)))
        assertEquals("Last seen 1 yr ago", text(now.minusYears(1)))
        assertEquals("Last seen 11 months ago", text(now.minusMonths(11)))
        assertEquals("Last seen 1 month ago", text(now.minusMonths(1)))
        assertEquals("Last seen 3 days ago", text(now.minusDays(3)))
        assertEquals("Nothing signed by them found", WotZombies.lastSeenText(0, now.toEpochSecond(), ZoneOffset.UTC))
        assertNotNull(WotZombies.lastSeenText(now.plusDays(2).toEpochSecond(), now.toEpochSecond(), ZoneOffset.UTC))
    }
}

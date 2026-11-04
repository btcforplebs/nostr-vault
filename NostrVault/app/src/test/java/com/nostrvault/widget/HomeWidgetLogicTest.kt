package com.nostrvault.widget

import com.nostrvault.data.model.LiveStream
import com.nostrvault.ui.navigation.DeepLinkRouter
import com.nostrvault.ui.navigation.NostrEntityDecoder
import com.nostrvault.ui.navigation.Screen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** Live now and On this day widget rules: the same cases as iOS LiveNowTests / OnThisDayTests. */
class HomeWidgetLogicTest {

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val service = "c".repeat(64)
    private val now = 1_800_000_000L

    private fun stream(
        signer: String,
        d: String,
        createdAt: Long = now - 60,
        status: String = "live",
        host: String? = null,
        url: String = "https://x.example/live.m3u8",
    ): LiveStream = LiveStream.from(
        signer,
        createdAt,
        listOfNotNull(
            listOf("d", d),
            listOf("status", status),
            listOf("streaming", url),
            listOf("title", "show $d"),
            host?.let { listOf("p", it, "", "host") },
        ),
    )!!

    // ── Live now ───────────────────────────────────────────────────────

    @Test fun `followed live streams come newest first`() {
        val picked = LiveNowRules.pick(
            listOf(stream(alice, "1", createdAt = now - 300), stream(bob, "2", createdAt = now - 60)),
            follows = setOf(alice, bob), blocked = emptySet(), nowSeconds = now,
        )
        assertEquals(listOf("2", "1"), picked.map { it.identifier })
    }

    @Test fun `an ended event replaces its own live announcement`() {
        val picked = LiveNowRules.pick(
            listOf(stream(alice, "1", createdAt = now - 600), stream(alice, "1", createdAt = now - 30, status = "ended")),
            follows = setOf(alice), blocked = emptySet(), nowSeconds = now,
        )
        assertEquals(emptyList<LiveStream>(), picked)
    }

    @Test fun `a service-signed stream counts when its tagged host is followed`() {
        val picked = LiveNowRules.pick(
            listOf(stream(service, "s", host = alice)),
            follows = setOf(alice), blocked = emptySet(), nowSeconds = now,
        )
        assertEquals(alice, picked.single().hostPubkey)
    }

    @Test fun `unfollowed, blocked, stale and unplayable streams stay out`() {
        val picked = LiveNowRules.pick(
            listOf(
                stream(bob, "unfollowed"),
                stream(service, "blocked", host = alice),
                stream(alice, "stale", createdAt = now - 2 * 60 * 60),
                stream(alice, "rtmp", url = "rtmp://x.example/live"),
            ),
            follows = setOf(alice, service), blocked = setOf(alice), nowSeconds = now,
        )
        assertEquals(emptyList<LiveStream>(), picked)
    }

    @Test fun `empty line says why`() {
        assertEquals("Nobody you follow is live right now.", LiveNowRules.emptyLine(true))
        assertEquals("Follow people to see when they go live.", LiveNowRules.emptyLine(false))
    }

    @Test fun `a widget tap round-trips a free-text address through the router`() {
        val address = "30311:$alice:my show/part 2?#%+"
        val link = "nostrvault://" + LiveNowRules.destination(address)
        val target = DeepLinkRouter.fromUri(link, NoDecoder)!!
        assertEquals(Screen.Feed.route, target.route)
        assertEquals(address, target.liveAddress)
    }

    @Test fun `the router refuses a live link that is not a stream address`() {
        assertNull(DeepLinkRouter.fromUri("nostrvault://live/30023%3A$alice%3Ax", NoDecoder))
        assertNull(DeepLinkRouter.fromUri("nostrvault://live/30311%3Anothex%3Ax", NoDecoder))
        assertNull(DeepLinkRouter.fromUri("nostrvault://live/30311%3A$alice%3A", NoDecoder))
        assertNull(DeepLinkRouter.fromUri("nostrvault://live", NoDecoder))
    }

    private object NoDecoder : NostrEntityDecoder {
        override fun noteToHex(note1: String): String? = null
        override fun neventToHex(nevent1: String): String? = null
        override fun npubToHex(npub: String): String? = null
        override fun nprofileToHex(nprofile: String): String? = null
        override fun naddrToCoordinate(naddr1: String) = null
    }

    // ── On this day ────────────────────────────────────────────────────

    private val zone = ZoneId.of("America/New_York")
    private fun ms(y: Int, m: Int, d: Int, h: Int = 12) =
        LocalDate.of(y, m, d).atTime(h, 0).atZone(zone).toInstant().toEpochMilli()

    @Test fun `windows are this local date one and two years back`() {
        val ws = OnThisDayRules.windows(ms(2026, 11, 4), zone = zone)
        assertEquals(listOf(1, 2), ws.map { it.years })
        assertEquals(ms(2025, 11, 4, 0) / 1000, ws[0].since)
        assertEquals(ms(2025, 11, 5, 0) / 1000, ws[0].until)
        assertEquals(ms(2024, 11, 4, 0) / 1000, ws[1].since)
    }

    @Test fun `a 25-hour day ends at the next local midnight`() {
        // 2025-11-02 is the DST end in New York: 25 hours long.
        val w = OnThisDayRules.window(ms(2026, 11, 2), 1, zone)!!
        assertEquals(25 * 3600L, w.until - w.since)
    }

    @Test fun `29 February has no window in a year without one`() {
        val ws = OnThisDayRules.windows(ms(2028, 2, 29), zone = zone)
        assertEquals(emptyList<OnThisDayRules.Window>(), ws)
    }

    @Test fun `own top-level notes inside the window, oldest first, capped, once each`() {
        val w = OnThisDayRules.window(ms(2026, 11, 4), 1, zone)!!
        fun note(id: String, at: Long, pubkey: String = alice, kind: Int = 1, tags: List<List<String>> = emptyList()) =
            OnThisDayRules.Note(id, pubkey, kind, at, "text $id", tags)
        val inside = w.since + 100
        val picked = OnThisDayRules.notes(
            listOf(
                note("late", inside + 500),
                note("early", inside),
                note("early", inside),
                note("mid", inside + 200),
                note("fourth", inside + 900),
                note("reply", inside + 1, tags = listOf(listOf("e", "f".repeat(64), "", "reply"))),
                note("someone", inside + 2, pubkey = bob),
                note("article", inside + 3, kind = 30023),
                note("before", w.since - 1),
                note("after", w.until),
            ),
            owner = alice, w = w,
        )
        assertEquals(listOf("early", "mid", "late"), picked.map { it.id })
    }

    @Test fun `line text drops media links, shortens other links, names media-only notes`() {
        assertEquals("Sunset at the beach", OnThisDayRules.lineText("Sunset  at\nthe beach https://x.example/a.JPG?w=1"))
        assertEquals("Photo", OnThisDayRules.lineText("https://x.example/a.png"))
        assertEquals("Photos", OnThisDayRules.lineText("https://x.example/a.png https://x.example/b.webp"))
        assertEquals("Video", OnThisDayRules.lineText(" https://blossom.example/f96e.mp4\n"))
        assertEquals("Note", OnThisDayRules.lineText("   "))
        assertEquals(
            "bet on it here: predyx.com",
            OnThisDayRules.lineText("bet on it here: https://www.predyx.com/market/will-the-reduce-data?x=1"),
        )
        assertEquals("nostr:npub1abc", OnThisDayRules.lineText("nostr:npub1abc"))
    }

    @Test fun `a widget alternates years, then lists by year`() {
        val picked = listOf(1 to listOf("a1", "a2", "a3"), 2 to listOf("b1"))
        assertEquals(listOf(1 to "a1", 1 to "a2", 2 to "b1"), OnThisDayRules.forWidget(picked, 3))
        assertEquals(listOf(1 to "a1"), OnThisDayRules.forWidget(picked, 1))
        assertEquals(listOf(2 to "b1"), OnThisDayRules.forWidget(listOf(1 to emptyList(), 2 to listOf("b1")), 3))
        assertEquals(emptyList<Pair<Int, String>>(), OnThisDayRules.forWidget(listOf(1 to emptyList<String>()), 3))
    }

    @Test fun `years text`() {
        assertEquals("1 year ago", OnThisDayRules.yearsText(1))
        assertEquals("2 years ago", OnThisDayRules.yearsText(2))
    }
}

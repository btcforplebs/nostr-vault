package com.nostrvault.data.model

import com.nostrvault.relay.HavenConfig
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class GlobalSearchTest {

    private fun note(id: String, pubkey: String, seconds: Long, content: String = "") = FeedNote(
        id = id,
        pubkey = pubkey,
        content = content,
        createdAt = Date(seconds * 1000),
        tags = emptyList(),
        kind = 1,
        repostedBy = null,
        isReply = false,
        replyToPubkey = null,
        parentEventId = null,
        mediaURLs = emptyList(),
        linkURLs = emptyList(),
        quotedEventIds = emptyList(),
        repostedEventId = null,
    )

    // ── Term matching ────────────────────────────────────────────────

    @Test
    fun `query shorter than two characters is refused`() {
        assertNull(SearchTermMatcher.create(""))
        assertNull(SearchTermMatcher.create(" a "))
        assertNotNull(SearchTermMatcher.create("ab"))
    }

    @Test
    fun `all terms must match, case-insensitively, in any order`() {
        val m = SearchTermMatcher.create("  Bitcoin   HAVEN ")!!
        assertEquals(listOf("bitcoin", "haven"), m.terms)
        assertTrue(m.matchesNote("haven runs on bitcoin"))
        assertTrue(m.matchesNote("BITCOIN and Haven"))
        assertFalse(m.matchesNote("just bitcoin"))
        assertFalse(m.matchesNote("just haven"))
    }

    @Test
    fun `a single term is a substring match`() {
        val m = SearchTermMatcher.create("vault")!!
        assertTrue(m.matchesNote("NostrVault shipped"))
        assertFalse(m.matchesNote("nothing here"))
    }

    @Test
    fun `profile terms may be spread across fields but each must appear`() {
        val m = SearchTermMatcher.create("logen photo")!!
        assertTrue(m.matchesProfile(displayName = "Logen", name = null, about = "photographer", nip05 = null, pubkey = "abc"))
        assertFalse(m.matchesProfile(displayName = "Logen", name = null, about = "writer", nip05 = null, pubkey = "abc"))
        val byKey = SearchTermMatcher.create("deadbeef")!!
        assertTrue(byKey.matchesProfile(null, null, null, null, "00deadbeef00"))
    }

    // ── Paging plan ──────────────────────────────────────────────────

    @Test
    fun `page size stays under Badger's 1000 cap`() {
        assertTrue(LocalRelaySearchPlan.PAGE_LIMIT <= 1000)
    }

    @Test
    fun `short page ends, full page advances with until`() {
        assertEquals(LocalRelaySearchPlan.Step.Done, LocalRelaySearchPlan.step(250, 250, 100L, 1))
        assertEquals(LocalRelaySearchPlan.Step.Next(100L), LocalRelaySearchPlan.step(1000, 1000, 100L, 1))
    }

    @Test
    fun `page of repeats or page cap ends`() {
        assertEquals(LocalRelaySearchPlan.Step.Done, LocalRelaySearchPlan.step(1000, 0, 100L, 2))
        assertEquals(
            LocalRelaySearchPlan.Step.Done,
            LocalRelaySearchPlan.step(1000, 1000, 100L, LocalRelaySearchPlan.MAX_PAGES),
        )
        assertEquals(LocalRelaySearchPlan.Step.Done, LocalRelaySearchPlan.step(1000, 1000, null, 1))
    }

    // ── NIP-11 ───────────────────────────────────────────────────────

    @Test
    fun `nip11 url is the http form of the ws url`() {
        assertEquals("https://mac.example.com", Nip11.httpUrl("wss://mac.example.com"))
        assertEquals("http://127.0.0.1:3355", Nip11.httpUrl("ws://127.0.0.1:3355"))
    }

    @Test
    fun `supported_nips containing 50 is detected`() {
        assertTrue(Nip11.supportsNip50("""{"name":"x","supported_nips":[1,11,50]}"""))
        assertTrue(Nip11.supportsNip50("""{"supported_nips":["1","50"]}"""))
        assertFalse(Nip11.supportsNip50("""{"supported_nips":[1,11,42]}"""))
        assertFalse(Nip11.supportsNip50("""{"name":"no nips"}"""))
        assertFalse(Nip11.supportsNip50("<html>not json</html>"))
    }

    // ── Wire parsing ─────────────────────────────────────────────────

    @Test
    fun `parses event, eose and closed`() {
        val ev = SearchWireMessage.parse(
            """["EVENT","s1",{"id":"e1","pubkey":"p1","kind":1,"content":"hi","created_at":42,"tags":[["t","x"]]}]""",
        )
        assertTrue(ev is SearchWireMessage.Event)
        ev as SearchWireMessage.Event
        assertEquals("s1", ev.subId)
        assertEquals("e1", ev.id)
        assertEquals(42L, ev.createdAt)
        assertEquals(listOf(listOf("t", "x")), ev.tags)

        assertEquals(SearchWireMessage.Eose("s1"), SearchWireMessage.parse("""["EOSE","s1"]"""))
        assertEquals(
            SearchWireMessage.Closed("s2", "we support only kind:0 search queries"),
            SearchWireMessage.parse("""["CLOSED","s2","we support only kind:0 search queries"]"""),
        )
        assertEquals(SearchWireMessage.Other, SearchWireMessage.parse("""["NOTICE","hello"]"""))
        assertEquals(SearchWireMessage.Other, SearchWireMessage.parse("garbage"))
    }

    @Test
    fun `profile metadata parses and rejects non-json`() {
        val p = parseProfileMetadata("pk", """{"name":"n","display_name":"D","about":"a","nip05":"x@y"}""")!!
        assertEquals("D", p.displayName)
        assertEquals("x@y", p.nip05)
        assertNull(parseProfileMetadata("pk", "not json"))
    }

    // ── Merge ────────────────────────────────────────────────────────

    @Test
    fun `notes dedupe by id, profiles by pubkey with newest kind 0 winning`() {
        val acc = GlobalSearchAccumulator()
        assertTrue(acc.addNote(note("a", "x", 1)))
        assertFalse(acc.addNote(note("a", "x", 1)))

        assertTrue(acc.addProfile(FeedProfile(pubkey = "p", name = "old"), 10))
        assertFalse(acc.addProfile(FeedProfile(pubkey = "p", name = "older"), 5))
        assertTrue(acc.addProfile(FeedProfile(pubkey = "p", name = "new"), 20))

        val r = acc.ranked(emptySet(), emptySet())
        assertEquals(1, r.notes.size)
        assertEquals(1, r.profiles.size)
        assertEquals("new", r.profiles.single().name)
    }

    // ── Ranking ──────────────────────────────────────────────────────

    @Test
    fun `own then follows then everyone, newest first within a tier`() {
        val notes = listOf(
            note("stranger-new", "s", 500),
            note("follow-old", "f", 100),
            note("own-old", "me", 50),
            note("follow-new", "f", 400),
            note("own-new", "me", 300),
            note("stranger-old", "s", 10),
        )
        val ranked = SearchRanking.rankNotes(notes, own = setOf("me"), follows = setOf("f"))
        assertEquals(
            listOf("own-new", "own-old", "follow-new", "follow-old", "stranger-new", "stranger-old"),
            ranked.map { it.id },
        )
    }

    @Test
    fun `profiles rank by tier and keep arrival order within one`() {
        val profiles = listOf(
            FeedProfile(pubkey = "s1"),
            FeedProfile(pubkey = "f"),
            FeedProfile(pubkey = "s2"),
            FeedProfile(pubkey = "me"),
        )
        val ranked = SearchRanking.rankProfiles(profiles, own = setOf("me"), follows = setOf("f"))
        assertEquals(listOf("me", "f", "s1", "s2"), ranked.map { it.pubkey })
    }

    // ── Source status ────────────────────────────────────────────────

    @Test
    fun `source status reports found, zero, and the reason for no answer`() {
        assertEquals(SearchSourceStatus.Found(3), finalSourceStatus(3, false, true, null, "boom"))
        assertEquals(SearchSourceStatus.Found(0), finalSourceStatus(0, true, false, null, null))
        assertEquals(SearchSourceStatus.NoAnswer("HTTP 403"), finalSourceStatus(0, false, false, null, "HTTP 403"))
        assertEquals(
            SearchSourceStatus.NoAnswer("auth-required: x"),
            finalSourceStatus(0, false, false, "auth-required: x", null),
        )
        assertEquals(SearchSourceStatus.NoAnswer("timed out"), finalSourceStatus(0, false, true, null, null))
    }

    // ── Relay list ───────────────────────────────────────────────────

    @Test
    fun `defaults drop nostr band and noswhere`() {
        assertEquals(
            listOf(
                "wss://nostr.wine",
                "wss://search.nos.today",
                "wss://relay.vertexlab.io",
                "wss://profiles.nostrver.se",
            ),
            DEFAULT_SEARCH_RELAYS,
        )
    }

    @Test
    fun `relay input is normalised or rejected`() {
        assertEquals("wss://nostr.wine", SearchRelayUrls.normalize(" nostr.wine/ "))
        assertEquals("ws://10.0.0.2:3355", SearchRelayUrls.normalize("ws://10.0.0.2:3355"))
        assertNull(SearchRelayUrls.normalize(""))
        assertNull(SearchRelayUrls.normalize("https://nostr.wine"))
        assertNull(SearchRelayUrls.normalize("wss://"))
        assertNull(SearchRelayUrls.normalize("has space.com"))
    }

    @Test
    fun `search relays persist in config json and reset to defaults`() {
        val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
        val fresh = HavenConfig()
        assertEquals(DEFAULT_SEARCH_RELAYS, fresh.activeSearchRelays)

        val custom = fresh.copy(searchRelays = listOf("wss://a.example"))
        val back = json.decodeFromString<HavenConfig>(json.encodeToString(custom))
        assertEquals(listOf("wss://a.example"), back.activeSearchRelays)

        val emptied = json.decodeFromString<HavenConfig>(json.encodeToString(fresh.copy(searchRelays = emptyList())))
        assertEquals(emptyList<String>(), emptied.activeSearchRelays)

        // An old config.json without the key reads as defaults.
        val legacy = json.decodeFromString<HavenConfig>("""{"ownerNpub":"npub1x"}""")
        assertEquals(DEFAULT_SEARCH_RELAYS, legacy.activeSearchRelays)
    }
}

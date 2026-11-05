package com.nostrvault.widget

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.LiveStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Following / Mentions widgets, events stored and Live now (bug hunt 2026-11-05 #7, #9, Live now). */
class WidgetFeedRulesTest {

    private val me = "a".repeat(64)
    private val friend = "b".repeat(64)
    private val stranger = "c".repeat(64)

    private fun note(id: String, by: String, at: Long, tags: List<List<String>> = emptyList()) = FeedNote.fromEvent(
        id = id, pubkey = by, content = "hi $id", tags = tags, createdAt = at, kind = 1,
    )

    private fun snap(id: String, by: String, at: Long) =
        VaultSnapshot.SnapshotNote(id = id, author = by, displayName = by.take(8), text = "hi $id", createdAt = at * 1000)

    private fun FeedNote.snap() = snap(id, pubkey, createdAt.time / 1000)

    // ── #7 Feed widget is Following, whatever feed is open ──────────────

    @Test
    fun globalFeedNotesByStrangersNeverReachTheFollowingWidget() {
        val open = listOf(note("1", stranger, 300), note("2", friend, 200), note("3", me, 100))
        val picked = WidgetFeedRules.followingNotes(open, authors = setOf(friend, me))
        assertEquals(listOf("2", "3"), picked.map { it.id })
    }

    @Test
    fun followingWidgetSkipsReplies() {
        val reply = note("r", friend, 300, tags = listOf(listOf("e", "x".repeat(64), "", "reply")))
        val picked = WidgetFeedRules.followingNotes(listOf(reply, note("2", friend, 200)), setOf(friend))
        assertEquals(listOf("2"), picked.map { it.id })
    }

    @Test
    fun unknownFollowListShowsNothingNewRatherThanStrangers() {
        val fresh = listOf(snap("1", stranger, 300))
        assertEquals(emptyList<VaultSnapshot.SnapshotNote>(), WidgetFeedRules.feed(fresh, authors = null, openFeedIsFollowing = false, previous = emptyList()))
    }

    @Test
    fun anotherFeedOpenKeepsTheFollowingNotesAlreadyShown() {
        val previous = listOf(snap("old1", friend, 100), snap("old2", friend, 50))
        val fresh = listOf(snap("new", friend, 200))
        val feed = WidgetFeedRules.feed(fresh, setOf(friend), openFeedIsFollowing = false, previous = previous)
        assertEquals(listOf("new", "old1", "old2"), feed.map { it.id })
    }

    @Test
    fun followingOpenReplacesTheList() {
        val previous = listOf(snap("old", friend, 100))
        val fresh = listOf(snap("new", friend, 200))
        assertEquals(listOf("new"), WidgetFeedRules.feed(fresh, setOf(friend), openFeedIsFollowing = true, previous = previous).map { it.id })
    }

    @Test
    fun carriedNotesOfSomeoneUnfollowedDrop() {
        val previous = listOf(snap("old", stranger, 100))
        assertEquals(emptyList<String>(), WidgetFeedRules.feed(emptyList(), setOf(friend), false, previous).map { it.id })
    }

    // ── #7 Mentions come from your inbox too ────────────────────────────

    private fun event(id: String, by: String, at: Long, kind: Int = 1, tags: String = """[["p","$me"]]"""): JsonObject =
        Json.parseToJsonElement(
            """{"id":"$id","pubkey":"$by","created_at":$at,"kind":$kind,"tags":$tags,"content":"line one\nline two","sig":""}""",
        ).jsonObject

    @Test
    fun inboxMentionsFromStrangersCount() {
        val events = listOf(
            event("m1", stranger, 300),
            event("own", me, 250),
            event("other", stranger, 200, tags = """[["p","$friend"]]"""),
            event("zap", stranger, 150, kind = 9735),
        )
        val got = WidgetFeedRules.inboxMentions(events, me, blocked = emptySet())
        assertEquals(listOf("m1"), got.map { it.id })
        assertEquals("line one line two", got.single().text)
        assertEquals(300_000L, got.single().createdAt)
    }

    @Test
    fun blockedAuthorsAreNotMentions() {
        assertTrue(WidgetFeedRules.inboxMentions(listOf(event("m1", stranger, 300)), me, blocked = setOf(stranger)).isEmpty())
    }

    @Test
    fun mentionsMergeFeedAndInboxNewestFirstOnce() {
        val fromFeed = listOf(snap("f", friend, 200), snap("both", friend, 100))
        val fromInbox = listOf(snap("i", stranger, 300), snap("both", friend, 100))
        assertEquals(listOf("i", "f", "both"), WidgetFeedRules.mentions(fromFeed, fromInbox).map { it.id })
    }

    // ── #9 Events stored after a reboot ─────────────────────────────────

    @Test
    fun uncountedRelayKeepsTheLastKnownEventCount() {
        assertEquals(4_210, WidgetFeedRules.eventsStored(fresh = null, previous = 4_210))
    }

    @Test
    fun aRealCountReplacesTheOldOne() {
        assertEquals(12, WidgetFeedRules.eventsStored(fresh = 12, previous = 4_210))
        assertEquals(0, WidgetFeedRules.eventsStored(fresh = 0, previous = 4_210))
    }

    // ── Live now drops streams no longer on air ─────────────────────────

    private fun live(address: String, at: Long, status: String = "live", ends: Long? = null) = VaultSnapshot.LiveItem(
        address = address, host = friend, hostName = "f", title = "t", author = friend, createdAt = at,
        tags = buildList {
            add(listOf("d", address))
            add(listOf("status", status))
            add(listOf("streaming", "https://x.example/$address.m3u8"))
            ends?.let { add(listOf("ends", "$it")) }
        },
    )

    @Test
    fun liveNowDropsStreamsNotRefreshedWithinAnHour() {
        val now = 1_800_000_000L
        val items = listOf(live("fresh", now - 60), live("old", now - LiveStream.STALE_AFTER_SECONDS - 60))
        assertEquals(listOf("fresh"), LiveNowRules.onAir(items, now).map { it.address })
    }

    @Test
    fun liveNowDropsEndedStreams() {
        val now = 1_800_000_000L
        val items = listOf(live("ended", now - 60, status = "ended"), live("past", now - 60, ends = now - 10))
        assertTrue(LiveNowRules.onAir(items, now).isEmpty())
    }
}

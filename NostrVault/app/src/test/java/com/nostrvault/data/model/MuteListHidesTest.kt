package com.nostrvault.data.model

import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.FeedFilterEngine
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Muted words, hashtags and threads from a kind 10000 (Apple: MuteList.swift). */
class MuteListHidesTest {
    private val thread = "e".repeat(64)
    private val friend = "f".repeat(64)
    private val me = "a".repeat(64)

    private fun rules(vararg tags: List<String>) = MuteRules(MutedThings.from(tags.toList()))
    private fun note(id: String, content: String, tags: List<List<String>> = emptyList(), pubkey: String = friend, kind: Int = 1) =
        FeedNote.fromEvent(id, pubkey, content, tags, 1_700_000_000L, kind)

    @Test fun `reads word, t and e entries, lowercased and deduped`() {
        val t = MutedThings.from(listOf(listOf("word", " Spam "), listOf("word", "spam"), listOf("t", "#NSFW"),
            listOf("e", thread.uppercase()), listOf("e", "not-hex"), listOf("p", friend), listOf("word", "")))
        assertEquals(listOf("spam"), t.words)
        assertEquals(listOf("nsfw"), t.hashtags)
        assertEquals(listOf(thread), t.threads)
    }

    @Test fun `whole words only, any case`() {
        val r = rules(listOf("word", "ass"))
        assertTrue(r.hidesText("what an ASS!"))
        assertTrue(r.hidesText("ass"))
        assertTrue(r.hidesText("#ass"))
        assertFalse(r.hidesText("first class"))
        assertFalse(r.hidesText("assassin"))
        assertFalse(r.hidesText("ass2"))
    }

    @Test fun `phrases and non-Latin letters keep their boundaries`() {
        val r = rules(listOf("word", "bad day"), listOf("word", "café"))
        assertTrue(r.hidesText("A Bad Day, again"))
        assertFalse(r.hidesText("bad daydream"))
        assertTrue(r.hidesText("Le CAFÉ."))
        assertFalse(r.hidesText("cafés"))
    }

    @Test fun `regex characters in a word are literal`() {
        val r = rules(listOf("word", "a.b"))
        assertTrue(r.hidesText("see a.b here"))
        assertFalse(r.hidesText("see axb here"))
    }

    @Test fun `hashtags and threads`() {
        val r = rules(listOf("t", "nsfw"), listOf("e", thread))
        assertTrue(r.hides("1".repeat(64), "hi", listOf(listOf("t", "#NSFW"))))
        assertTrue(r.hides(thread, "the root", emptyList()))
        assertTrue(r.hides("2".repeat(64), "a reply", listOf(listOf("e", thread, "", "root"))))
        assertTrue(r.hides("3".repeat(64), "a reply", emptyList(), parentId = thread))
        // A quote of the thread is not in it.
        assertFalse(r.hides("4".repeat(64), "look", listOf(listOf("e", thread, "", "mention"))))
        assertFalse(MuteRules.NONE.hides(thread, "x", emptyList()))
    }

    @Test fun `entries keep public and private apart, private unknown when unopened`() = runBlocking {
        val tags = listOf(listOf("word", "pub"))
        val opened = MuteList.entries(tags, "enc:[[\"word\",\"secret\"]]") { c, _ -> c.removePrefix("enc:") }
        assertEquals(listOf("pub"), opened.publicMuted.words)
        assertEquals(listOf("secret"), opened.privateMuted?.words)
        val shut = MuteList.entries(tags, "enc:x") { _, _ -> null }
        assertNull(shut.privateMuted)
        assertEquals(MutedThings.EMPTY, MuteList.entries(tags, "") { _, _ -> null }.privateMuted)
    }

    @Test fun `config joins public and private for the account`() {
        val cfg = HavenConfig(ownerNpub = "npub1me",
            mutedPerAccount = mapOf("npub1me" to MutedThings(words = listOf("pub"))),
            privateMutedPerAccount = mapOf("npub1me" to MutedThings(words = listOf("secret"))))
        assertTrue(cfg.muteRulesForActiveAccount().hidesText("a secret"))
        assertTrue(cfg.muteRulesForActiveAccount().hidesText("a pub"))
        assertTrue(cfg.muteRulesFor("npub1other").isEmpty)
    }

    @Test fun `feed drops muted notes but never your own`() {
        val r = rules(listOf("word", "crypto"))
        val theirs = note("1".repeat(64), "buy crypto now")
        val mine = note("2".repeat(64), "my crypto post", pubkey = me)
        val clean = note("3".repeat(64), "morning walk")
        val shown = FeedFilterEngine.filterFeedNotes(
            notes = listOf(theirs, mine, clean), mode = FeedMode.FOLLOWING, blocked = emptySet(),
            showReposts = true, showReplies = true, followedPubkeys = setOf(friend, me), wotPubkeys = emptySet(),
            ownPubkeys = setOf(me), mutes = r,
        )
        assertEquals(listOf(mine.id, clean.id).toSet(), shown.map { it.id }.toSet())
        val media = FeedFilterEngine.filterMediaNotes(listOf(note("4".repeat(64), "crypto https://x.io/a.jpg")),
            emptySet(), emptySet(), isGlobalMedia = false, mutes = r)
        assertTrue(media.isEmpty())
    }
}

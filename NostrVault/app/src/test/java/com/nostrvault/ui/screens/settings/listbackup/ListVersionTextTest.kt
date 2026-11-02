package com.nostrvault.ui.screens.settings.listbackup

import com.nostrvault.service.ListVersion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The words on the list versions, restore and merge screens: who saved a version, its count and change, the titles. */
class ListVersionTextTest {
    private val alice = "a".repeat(64)
    private fun people(n: Int, from: Int = 0) = (from until from + n).map { listOf("p", it.toString(16).padStart(64, '0')) }
    private fun v(kind: Int, tags: List<List<String>>, content: String = "", at: Long = 1_700_000_000) =
        ListVersion("id$at", alice, kind, at, tags, content)

    @Test fun appNameIsTheFirstClientTag() {
        assertEquals("Primal", ListVersionText.appName(listOf(listOf("p", alice), listOf("client", "Primal", "31990:x:y"), listOf("client", "Damus"))))
    }

    @Test fun appNameWithoutAClientTagIsUnknown() {
        assertEquals("An unknown app", ListVersionText.appName(listOf(listOf("p", alice))))
        assertEquals("An unknown app", ListVersionText.appName(listOf(listOf("client", "  "), listOf("client"))))
        assertEquals("an unknown app", ListVersionText.appInSentence(emptyList()))
        assertEquals("Amethyst", ListVersionText.appInSentence(listOf(listOf("client", " Amethyst "))))
    }

    @Test fun titleStartsWithTheApp() {
        assertTrue(ListVersionText.title(v(3, people(1) + listOf(listOf("client", "Primal")))).startsWith("Primal, "))
    }

    @Test fun countUsesTheListsWord() {
        assertEquals("300 follows", ListVersionText.count(v(3, people(300) + listOf(listOf("client", "Primal")))))
        assertEquals("1 follow", ListVersionText.count(v(3, people(1))))
        assertEquals("12 muted", ListVersionText.count(v(10000, people(12))))
        assertEquals("12 muted + private", ListVersionText.count(v(10000, people(12), content = "secret")))
        assertEquals("4 relays", ListVersionText.count(v(10050, (1..4).map { listOf("relay", "wss://r$it.example") })))
        assertEquals("1 community", ListVersionText.count(v(10004, listOf(listOf("a", "34550:x:y")))))
        assertEquals("2 fields", ListVersionText.count(v(0, emptyList(), content = """{"name":"a","about":"b"}""")))
    }

    @Test fun changeIsAgainstTheVersionJustOlder() {
        val big = v(3, people(1009), at = 1)
        val wiped = v(3, people(300), at = 2)
        assertEquals("−709", ListVersionText.change(wiped, big))
        assertEquals("300 follows, −709", ListVersionText.detail(wiped, big))
        val edited = v(3, people(298, from = 2) + people(3, from = 5000), at = 3)
        assertEquals("+3, −2", ListVersionText.change(edited, wiped))
        assertEquals("no change", ListVersionText.change(v(3, people(300), at = 4), wiped))
        assertNull(ListVersionText.change(big, null))
        assertEquals("1009 follows", ListVersionText.detail(big, null))
    }

    @Test fun sectionTitlesPerList() {
        assertEquals("Will follow again", ListVersionText.willAdd(3))
        assertEquals("Will unfollow", ListVersionText.willRemove(3))
        assertEquals("Still following", ListVersionText.stillIn(3))
        assertEquals("Will mute again", ListVersionText.willAdd(10000))
        assertEquals("Will unmute", ListVersionText.willRemove(10000))
        assertEquals("Still muted", ListVersionText.stillIn(10000))
        assertEquals("Will add back", ListVersionText.willAdd(10003))
        assertEquals("Will remove", ListVersionText.willRemove(10003))
        assertEquals("Already in your list", ListVersionText.stillIn(10003))
    }

    @Test fun followConfirmOnlyForFollows() {
        assertEquals("Saves your follows: you follow 709 again.", ListVersionText.followConfirm(3, 709, 0))
        assertEquals("Saves your follows: you follow 709 again, 2 unfollowed.", ListVersionText.followConfirm(3, 709, 2))
        assertNull(ListVersionText.followConfirm(10000, 3, 0))
    }

    @Test fun mergeBlurbSaysWhatMergeKeeps() {
        assertTrue(ListVersionText.mergeBlurb(3).startsWith("Keeps everyone you follow now"))
        assertTrue(ListVersionText.mergeBlurb(10003).startsWith("Keeps everything in your list now"))
    }

    @Test fun personKeyOnlyForPeople() {
        assertEquals(alice, ListVersionText.personKey("p\u0000${alice.uppercase()}"))
        assertNull(ListVersionText.personKey("t\u0000nostr"))
        assertNull(ListVersionText.personKey("p\u0000not-hex"))
        assertEquals(alice, ListVersionText.personTag(listOf("p", alice, "wss://r.example", "pet")))
        assertNull(ListVersionText.personTag(listOf("e", alice)))
    }
}

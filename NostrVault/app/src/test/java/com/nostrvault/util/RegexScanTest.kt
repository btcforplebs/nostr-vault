package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RegexScanTest {
    private fun same(regex: Regex, input: String) {
        val want = regex.findAll(input).toList()
        val got = regex.findAllOnce(input).toList()
        assertEquals("count for /$regex/", want.size, got.size)
        want.zip(got).forEach { (w, g) ->
            assertEquals(w.value, g.value)
            assertEquals(w.range, g.range)
            assertEquals(w.groupValues, g.groupValues)
            assertEquals(w.groups.toList(), g.groups.toList())
            assertEquals(w.next()?.range, g.next()?.range)
        }
    }

    @Test
    fun matchesExactlyWhatFindAllMatches() {
        val text = "see https://a.example/x, and https://b.example/y. #nostr #Vault nostr:npub1abc ok"
        same(Regex("""https?://[^\s<>")\]]*[^\s<>")\].,;:!?'"]""", RegexOption.IGNORE_CASE), text)
        same(Regex("""#(\w+)"""), text)
        same(Regex("""nostr:(npub1\w+)|(nope)"""), text)  // an unmatched group stays null / ""
        same(Regex("x*"), "axxbx")  // empty matches advance as findAll's do
        same(Regex("q"), text)  // no match at all
    }

    @Test
    fun unmatchedGroupIsNullInGroupsAndEmptyInGroupValues() {
        val m = Regex("""(a)|(b)""").findAllOnce("b").single()
        assertNull(m.groups[1])
        assertEquals("", m.groupValues[1])
        assertEquals(MatchGroup("b", 0..0), m.groups[2])
    }

    @Test
    fun scansAHugeNoteFullOfLinks() {
        // The note shape that ran the Moto out of memory: many links in one long body.
        val note = (1..5_000).joinToString(" ") { "https://example.com/$it" }
        assertEquals(5_000, Regex("""https?://\S+""").findAllOnce(note).count())
    }

    /**
     * On Android every findAll match copies the whole input into native memory
     * (see [findAllOnce]); a long note took Logen's Moto past 2 GB. No scan in
     * the app may go back to it. Source-level: the JVM's regex has no such copy.
     */
    @Test
    fun theAppNeverCallsRegexFindAll() {
        val offenders = File("src/main/java").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { f -> f.readLines().mapIndexedNotNull { i, line -> if (".findAll(" in line) "${f.path}:${i + 1}" else null } }
            .toList()
        assertTrue("use findAllOnce, not Regex.findAll:\n" + offenders.joinToString("\n"), offenders.isEmpty())
    }
}

package com.nostrvault.service

import com.nostrvault.data.model.MuteList
import com.nostrvault.data.model.MutedThings
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/** Muting and unmuting a word in the mute list's encrypted part, every other entry kept. */
class MutedWordsEditTest {
    private fun seal(text: String, nip04: Boolean): String {
        val body = Base64.getEncoder().encodeToString(text.toByteArray())
        return if (nip04) "$body?iv=AAAA" else "v2:$body"
    }

    private fun open(text: String, nip04: Boolean): String? = runCatching {
        String(Base64.getDecoder().decode(if (nip04) text.substringBefore('?') else text.removePrefix("v2:")))
    }.getOrNull()

    private fun edit(
        content: String, add: List<String> = emptyList(), remove: List<String> = emptyList(),
        mayBePrivate: Boolean = true, decrypt: (String, Boolean) -> String? = ::open,
    ) = runBlocking {
        ListMerge.editingPrivateTags(content, "word", add, remove, mayBePrivate,
            decrypt = { t, n -> decrypt(t, n) }, encrypt = { t, n -> seal(t, n) })
    }

    private val part = """[["p","aaa"],["word","spoiler"],["e","thread1"]]"""

    private fun tagsOf(result: ListMerge.PrivateEdit, nip04: Boolean = false): List<List<String>> =
        MuteList.privateTags(open((result as ListMerge.PrivateEdit.Done).content, nip04)!!)!!

    @Test fun `adds a word and keeps everything else`() {
        val r = edit(seal(part, false), add = listOf("crypto"))
        assertEquals(listOf(listOf("p", "aaa"), listOf("word", "spoiler"), listOf("e", "thread1"), listOf("word", "crypto")), tagsOf(r))
    }

    @Test fun `removes only that word, in the scheme it came in`() {
        val r = edit(seal(part, true), remove = listOf("SPOILER"))
        assertTrue((r as ListMerge.PrivateEdit.Done).content.contains("?iv="))
        assertEquals(listOf(listOf("p", "aaa"), listOf("e", "thread1")), tagsOf(r, nip04 = true))
    }

    @Test fun `an empty list starts a NIP-44 part`() {
        assertEquals(listOf(listOf("word", "x")), tagsOf(edit("", add = listOf("x"))))
    }

    @Test fun `nothing to change leaves the content as it is`() {
        val content = seal(part, false)
        assertSame(content, (edit(content, remove = listOf("absent")) as ListMerge.PrivateEdit.Done).content)
        assertEquals("", (edit("", remove = listOf("x")) as ListMerge.PrivateEdit.Done).content)
    }

    @Test fun `an unopened part refuses an add, and a removal of a word it may hold`() {
        val content = seal(part, false)
        val shut: (String, Boolean) -> String? = { _, _ -> null }
        assertEquals(ListMerge.PrivateEdit.Failed, edit(content, add = listOf("x"), decrypt = shut))
        assertEquals(ListMerge.PrivateEdit.Failed, edit(content, remove = listOf("spoiler"), decrypt = shut))
        assertSame(content, (edit(content, remove = listOf("pub"), mayBePrivate = false, decrypt = shut) as ListMerge.PrivateEdit.Done).content)
    }

    @Test fun `a part that is not a list of tags is never rewritten`() {
        assertEquals(ListMerge.PrivateEdit.Failed, edit(seal("""{"a":1}""", false), add = listOf("x")))
    }

    @Test fun `normalize folds case and spaces, refuses blank and long`() {
        assertEquals("bad day", MutedWords.normalize("  Bad   Day "))
        assertNull(MutedWords.normalize("   "))
        assertNull(MutedWords.normalize("x".repeat(MutedWords.MAX_LENGTH + 1)))
    }

    @Test fun `an unmute takes another app's word as stored`() {
        val odd = "foo  bar"
        val long = "y".repeat(MutedWords.MAX_LENGTH + 5)
        assertEquals("foo  bar", MutedWords.changed(add = null, remove = " Foo  Bar "))
        assertEquals(long, MutedWords.changed(add = null, remove = long))
        assertEquals("foo bar", MutedWords.changed(add = "Foo  Bar", remove = null))
        assertNull(MutedWords.changed(add = long, remove = null))
        val tags = listOf(listOf("word", odd), listOf("word", long), listOf("p", "aaa"))
        assertEquals(listOf(listOf("word", long), listOf("p", "aaa")),
            ListMerge.edit("word", tags, emptyList(), listOf(MutedWords.changed(null, odd)!!)))
        val r = edit(seal("""[["word","foo  bar"],["p","aaa"]]""", false), remove = listOf(MutedWords.changed(null, odd)!!))
        assertEquals(listOf(listOf("p", "aaa")), tagsOf(r))
    }

    @Test fun `rows show each word once, private wins`() {
        val rows = mutedWordRows(MutedThings(words = listOf("b", "a")), MutedThings(words = listOf("a")))
        assertEquals(listOf(MutedWordRow("a", true), MutedWordRow("b", false)), rows)
        assertEquals(listOf(MutedWordRow("b", false)), mutedWordRows(MutedThings(words = listOf("b")), null))
    }
}

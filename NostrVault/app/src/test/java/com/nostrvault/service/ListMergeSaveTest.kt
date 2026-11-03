package com.nostrvault.service

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a merged list saves: refuses an empty result, a relay list, and a base whose private part wasn't read; keeps
 * kind 3's content; encrypts private entries to self with NIP-44 (also over a NIP-04 list), checked by opening them again;
 * none means an empty content. The safe save around it (stale list, undo copy, signer, account) is
 * [ListVersionSaveTest]. Port of web-vault/test/list-merge-save.test.mjs; stand-in cipher, nothing is published.
 */
class ListMergeSaveTest {
    private val me = "a".repeat(64)

    private fun base(kind: Int, content: String = "", tags: List<List<String>> = listOf(listOf("p", "1"))) =
        NostrEvent("base", me, 100, kind, tags, content, "sig")

    /** NIP-44 stand-in: "n44:" + text; NIP-04: text + "?iv=x". */
    private val encrypt: suspend (String, Boolean) -> String? = { text, nip04 -> if (nip04) "$text?iv=x" else "n44:$text" }
    private val decrypt: suspend (String, Boolean) -> String? = { text, nip04 ->
        when {
            nip04 && text.endsWith("?iv=x") -> text.removeSuffix("?iv=x")
            !nip04 && text.startsWith("n44:") -> text.removePrefix("n44:")
            else -> null
        }
    }

    @Test
    fun `refuses an empty result, a relay list, and a private part not read`() {
        val v = ListVersion.of(base(10000, "old-cipher"))
        assertTrue(ListMergeSave.refusal(10003, null, false, listOf(listOf("client", "x")), emptyList())!!.contains("would be empty"))
        assertTrue(ListMergeSave.refusal(10002, null, false, listOf(listOf("r", "wss://b.example")), emptyList())!!.contains("can't be merged"))
        assertTrue(
            "a private part not read is refused here, not only by the page",
            ListMergeSave.refusal(10000, v, false, listOf(listOf("p", "1")), listOf(listOf("p", "2")))!!.contains("couldn't be opened, so saving would wipe it"),
        )
        assertNull(ListMergeSave.refusal(10000, v, true, listOf(listOf("p", "1")), listOf(listOf("p", "2"))))
        assertNull("only private entries is not empty", ListMergeSave.refusal(10000, null, false, emptyList(), listOf(listOf("p", "2"))))
        assertNull("kind 3 content is never a private part", ListMergeSave.refusal(3, ListVersion.of(base(3, "{}")), false, listOf(listOf("p", "1")), emptyList()))
    }

    @Test
    fun `kind 3 keeps the current content`() = runTest {
        val tags = listOf(listOf("p", "1"), listOf("p", "2"))
        val built = ListMergeSave.build(3, base(3, """{"wss://keep":{}}"""), tags, emptyList(), encrypt, decrypt) as ListVersionSave.Build.Ready
        assertEquals("""{"wss://keep":{}}""", built.content)
        assertEquals(tags, built.tags)
    }

    @Test
    fun `private entries are encrypted to self, none means an empty content`() = runTest {
        val built = ListMergeSave.build(10000, base(10000, "n44:old"), listOf(listOf("p", "1")), listOf(listOf("p", "2")), encrypt, decrypt)
        assertEquals("""n44:[["p","2"]]""", (built as ListVersionSave.Build.Ready).content)
        val none = ListMergeSave.build(10000, base(10000, "n44:old"), listOf(listOf("p", "1")), emptyList(), encrypt, decrypt)
        assertEquals("every private entry unticked: no private part", "", (none as ListVersionSave.Build.Ready).content)
        val first = ListMergeSave.build(10003, null, emptyList(), listOf(listOf("e", "2")), encrypt, decrypt)
        assertEquals("no list yet: NIP-44", """n44:[["e","2"]]""", (first as ListVersionSave.Build.Ready).content)
    }

    @Test
    fun `NIP-44 always, also over a NIP-04 list`() = runTest {
        val built = ListMergeSave.build(10000, base(10000, "abc?iv=def"), emptyList(), listOf(listOf("p", "2")), encrypt, decrypt)
        assertEquals("""n44:[["p","2"]]""", (built as ListVersionSave.Build.Ready).content)
    }

    @Test
    fun `a signer that can't encrypt, echoes the text or changes the scheme is refused`() = runTest {
        val priv = listOf(listOf("p", "2"))
        val cases = listOf<suspend (String, Boolean) -> String?>(
            { _, _ -> null },
            { _, _ -> throw IllegalStateException("signer offline") },
            { text, _ -> text },
            { text, _ -> "$text?iv=x" }, // NIP-04 where NIP-44 was asked
        )
        for (bad in cases) {
            val built = ListMergeSave.build(10000, base(10000, "n44:old"), emptyList(), priv, bad, decrypt)
            assertTrue(built is ListVersionSave.Build.Refuse)
        }
        val wrongKey = ListMergeSave.build(10000, base(10000, "n44:old"), emptyList(), priv, encrypt) { _, _ -> "[]" }
        assertTrue("opened again it must give back the same entries", wrongKey is ListVersionSave.Build.Refuse)
    }

    @Test
    fun `versions from another account are refused - a page left open across an account switch`() {
        val a = "a".repeat(64)
        val b = "b".repeat(64)
        assertNull(ListMergeSave.authorRefusal(a, setOf(a)))
        assertNotNull(ListMergeSave.authorRefusal(b, setOf(a)))
        assertNotNull(ListMergeSave.authorRefusal(a, setOf(a, b)))
        assertNotNull(ListMergeSave.authorRefusal(a, emptySet()))
        assertNotNull(ListMergeSave.authorRefusal("", setOf("")))
    }
}

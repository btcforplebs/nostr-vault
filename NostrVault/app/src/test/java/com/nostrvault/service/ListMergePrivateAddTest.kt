package com.nostrvault.service

import com.nostrvault.data.model.MuteList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/** Blocking privately: the person goes in the mute list's encrypted part. iOS: ListMergePrivateAddTests. */
class ListMergePrivateAddTest {
    /** Stand-in for NIP-44/NIP-04 to self: NIP-04 output carries "?iv=" as the real one does. */
    private fun seal(text: String, nip04: Boolean): String {
        val body = Base64.getEncoder().encodeToString(text.toByteArray())
        return if (nip04) "$body?iv=AAAA" else "v2:$body"
    }

    private fun open(text: String, nip04: Boolean): String? = runCatching {
        String(Base64.getDecoder().decode(if (nip04) text.substringBefore('?') else text.removePrefix("v2:")))
    }.getOrNull()

    private val schemes = mutableListOf<Boolean>()

    private fun block(
        content: String,
        add: List<String>,
        encrypt: (String, Boolean) -> String? = ::seal,
    ) = runBlocking {
        schemes.clear()
        ListMerge.addingPrivate(
            content, add,
            decrypt = { text, nip04 -> schemes += nip04; open(text, nip04) },
            encrypt = { text, nip04 -> schemes += nip04; encrypt(text, nip04) },
        )
    }

    private val privatePart = """[["p","aaa"],["p","bbb","wss://r.example/","pet"],["word","spoiler"],["e","thread1"]]"""

    @Test
    fun privateBlockKeepsEverythingElseInTheNip44Part() {
        val result = block(seal(privatePart, false), listOf("ccc")) as ListMerge.PrivateEdit.Done
        assertFalse(MuteList.isNip04(result.content))
        assertEquals(
            listOf(listOf("p", "aaa"), listOf("p", "bbb", "wss://r.example/", "pet"), listOf("word", "spoiler"),
                listOf("e", "thread1"), listOf("p", "ccc")),
            MuteList.privateTags(open(result.content, false)!!),
        )
        assertEquals("opened, encrypted, opened again to check", listOf(false, false, false), schemes)
    }

    @Test
    fun privateBlockKeepsANip04PartNip04() {
        val result = block(seal(privatePart, true), listOf("ccc")) as ListMerge.PrivateEdit.Done
        assertTrue(MuteList.isNip04(result.content))
        assertTrue(MuteList.privateTags(open(result.content, true)!!)!!.contains(listOf("p", "ccc")))
        assertEquals(listOf(true, true, true), schemes)
    }

    @Test
    fun aListWithNoPrivatePartStartsANip44One() {
        val result = block("  ", listOf("ccc")) as ListMerge.PrivateEdit.Done
        assertFalse(MuteList.isNip04(result.content))
        assertEquals("""[["p","ccc"]]""", open(result.content, false))
        assertEquals("encrypted, opened again to check", listOf(false, false), schemes)
    }

    @Test
    fun someoneAlreadyInThePrivatePartIsNotAddedTwice() {
        val result = block(seal(privatePart, false), listOf("AAA")) as ListMerge.PrivateEdit.Done
        val tags = MuteList.privateTags(open(result.content, false)!!)!!
        assertEquals(1, tags.count { it[0] == "p" && it[1].lowercase() == "aaa" })
    }

    /** A signer that won't decrypt must not publish a new part over one it never read. */
    @Test
    fun aPrivatePartThisDeviceCantOpenIsNotReplaced() {
        assertEquals(ListMerge.PrivateEdit.Failed, block("v2:not base64!", listOf("ccc")))
        assertEquals("opened, never encrypted", listOf(false), schemes)
    }

    @Test
    fun aPrivatePartARewriteWouldLoseIsNotReplaced() {
        assertEquals(ListMerge.PrivateEdit.Failed, block(seal("""[["p","aaa",null],{"x":"y"}]""", false), listOf("ccc")))
        assertNull(ListMerge.privateAdded("""{"p":"aaa"}""", listOf("ccc")))
    }

    @Test
    fun notPublishedWhenTheSignerCantEncryptOrEchoesThePlaintext() {
        assertEquals(ListMerge.PrivateEdit.Failed, block(seal(privatePart, false), listOf("ccc")) { _, _ -> null })
        assertEquals(ListMerge.PrivateEdit.Failed, block(seal(privatePart, false), listOf("ccc")) { _, _ -> error("signer") })
        assertEquals(ListMerge.PrivateEdit.Failed, block("", listOf("ccc")) { text, _ -> text })
        // NIP-04 asked, NIP-44 given back: the scheme would change under other apps.
        assertEquals(ListMerge.PrivateEdit.Failed, block(seal(privatePart, true), listOf("ccc")) { text, _ -> seal(text, false) })
    }

    @Test
    fun nobodyToAddPublishesNothing() {
        assertEquals(ListMerge.PrivateEdit.Failed, block(seal(privatePart, false), emptyList()))
        assertEquals(emptyList<Boolean>(), schemes)
    }
}

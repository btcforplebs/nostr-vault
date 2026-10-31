package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.nostrvault.data.model.MuteList
import kotlinx.coroutines.runBlocking
import java.util.Base64
import java.io.File
import java.nio.file.Files

/**
 * NIP-51 lists are replaceable: publishing only this device's entries used to
 * delete what other clients had set (review items D3, P3).
 */
class ListMergeTest {
    @Test
    fun `mute list keeps word, hashtag and thread mutes and replaces the p tags`() {
        val published = listOf(
            listOf("p", "aaa"), listOf("p", "gone"),
            listOf("word", "spoiler"), listOf("t", "nsfw"), listOf("e", "thread1"),
        )
        val tags = ListMerge.tags("p", listOf("aaa", "bbb"), published) { false }
        assertEquals(
            listOf(
                listOf("p", "aaa"), listOf("p", "bbb"),
                listOf("word", "spoiler"), listOf("t", "nsfw"), listOf("e", "thread1"),
            ),
            tags,
        )
    }

    @Test
    fun `an entry another client added stays, one removed here goes`() {
        val base = setOf("wss://removed.example", "wss://kept.example")
        val published = listOf(
            listOf("relay", "wss://kept.example"),
            listOf("relay", "wss://removed.example"),
            listOf("relay", "wss://other-client.example"),
        )
        val tags = ListMerge.tags("relay", listOf("wss://kept.example"), published) { ListMerge.key(it) !in base }
        assertEquals(
            listOf(listOf("relay", "wss://kept.example"), listOf("relay", "wss://other-client.example")),
            tags,
        )
    }

    @Test
    fun `no base yet keeps every published entry, once, after the local ones in order`() {
        val published = listOf(listOf("server", "https://b.example/"), listOf("server", "https://c.example"))
        val tags = ListMerge.tags("server", listOf("https://a.example", "https://B.example"), published) { true }
        assertEquals(
            listOf(listOf("server", "https://a.example"), listOf("server", "https://B.example"), listOf("server", "https://c.example")),
            tags,
        )
    }

    @Test
    fun `published first keeps their order and default, ours after`() {
        val published = listOf(
            listOf("server", "https://theirs.example"), listOf("alt", "x"),
            listOf("server", "https://B.example/"), listOf("server", "https://gone.example"),
        )
        // This device lists the Mac first and b; gone was removed here (in the base, not local).
        val tags = ListMerge.tagsPublishedFirst(
            "server", listOf("https://mac.example", "https://b.example", "https://theirs.example"), published,
        ) { it != "https://gone.example" }
        assertEquals(
            listOf(
                listOf("server", "https://theirs.example"), listOf("alt", "x"),
                listOf("server", "https://B.example/"), listOf("server", "https://mac.example"),
            ),
            tags,
        )
    }

    @Test
    fun `published first with nothing published is the local list`() {
        assertEquals(
            listOf(listOf("server", "https://a.example")),
            ListMerge.tagsPublishedFirst("server", listOf("https://a.example", "https://A.example/", " "), emptyList()) { true },
        )
    }

    @Test
    fun `nothing published publishes the local list`() {
        assertEquals(listOf(listOf("p", "x")), ListMerge.tags("p", listOf("x", "X", " "), emptyList()) { true })
    }

    @Test
    fun `bases are saved per list and survive a new instance`() {
        val file = File(Files.createTempDirectory("bases").toFile(), ListMerge.BASES_FILE)
        assertNull(ListMerge.Bases(file).get("10006:abc"))
        ListMerge.Bases(file).put("10006:abc", listOf("wss://a"))
        ListMerge.Bases(file).put("10063:abc", listOf("https://m"))
        assertEquals(listOf("wss://a"), ListMerge.Bases(file).get("10006:abc"))
        assertEquals(listOf("https://m"), ListMerge.Bases(file).get("10063:abc"))
    }

    // ── Block / unblock on a mute list another app wrote ──

    /** Amethyst's shape: public people, words, hashtags and a thread (its private part rides in content). */
    private val amethystList = listOf(
        listOf("p", "a1"), listOf("p", "b2", "wss://relay.example", "pet"), listOf("word", "spoiler"),
        listOf("t", "nsfw"), listOf("e", "thread1"), listOf("p", "C3"),
    )

    @Test
    fun `block keeps every old entry and adds one`() {
        assertEquals(amethystList + listOf(listOf("p", "d4")), ListMerge.edit("p", amethystList, listOf("d4"), emptyList()))
    }

    @Test
    fun `block of someone already listed changes nothing`() {
        assertEquals(amethystList, ListMerge.edit("p", amethystList, listOf("a1"), emptyList()))
    }

    @Test
    fun `unblock removes only that entry`() {
        assertEquals(
            listOf(
                listOf("p", "a1"), listOf("p", "b2", "wss://relay.example", "pet"), listOf("word", "spoiler"),
                listOf("t", "nsfw"), listOf("e", "thread1"),
            ),
            ListMerge.edit("p", amethystList, emptyList(), listOf("c3")),
        )
    }

    @Test
    fun `unblock leaves a word or thread with the same value`() {
        val base = listOf(listOf("word", "x"), listOf("e", "x"), listOf("p", "x"))
        assertEquals(listOf(listOf("word", "x"), listOf("e", "x")), ListMerge.edit("p", base, emptyList(), listOf("x")))
    }

    private fun list(createdAt: Long) = NostrEvent("", "me", createdAt, 10000, amethystList, "private", "")

    @Test
    fun `edit builds on the newer of the fetched and the held list`() {
        val fetched = NostrService.ReplaceableLookup(list(100), asked = 3, answered = 1)
        assertEquals(ListMerge.EditBase.Found(list(200)), ListMerge.editBase(fetched, list(200)))
        assertEquals(ListMerge.EditBase.Found(list(100)), ListMerge.editBase(fetched, null))
    }

    @Test
    fun `edit is not published when the fetch fails`() {
        assertEquals(ListMerge.EditBase.Unknown, ListMerge.editBase(NostrService.ReplaceableLookup(null, 3, 0), list(200)))
        assertEquals(ListMerge.EditBase.Unknown, ListMerge.editBase(NostrService.ReplaceableLookup(null, 3, 2), null))
        assertEquals(ListMerge.EditBase.None, ListMerge.editBase(NostrService.ReplaceableLookup(null, 3, 3), null))
    }

    @Test
    fun `edit is not published on a copy no own relay vouches for`() {
        val own = listOf("wss://mine.example")
        // Only purplepag.es answered; the user's relay timed out.
        val stale = NostrService.ReplaceableLookup(list(100), 3, 1, setOf("wss://purplepag.es"), setOf("wss://purplepag.es"))
        assertEquals(ListMerge.EditBase.Unknown, ListMerge.editBase(stale, list(50), own))
        // The user's relay sent it.
        val fromMine = NostrService.ReplaceableLookup(list(100), 3, 1, setOf("wss://mine.example/"), setOf("wss://mine.example/"))
        assertEquals(ListMerge.EditBase.Found(list(100)), ListMerge.editBase(fromMine, null, own))
        // The user's relay answered with an older copy; the newer one counts.
        val newerElsewhere = NostrService.ReplaceableLookup(list(100), 3, 2, setOf("wss://mine.example", "wss://purplepag.es"), setOf("wss://purplepag.es"))
        assertEquals(ListMerge.EditBase.Found(list(100)), ListMerge.editBase(newerElsewhere, null, own))
    }

    // Unblocking from the private part

    /** Stand-in for NIP-44/NIP-04 to self: NIP-04 output carries "?iv=" as the real one does. */
    private fun seal(text: String, nip04: Boolean): String {
        val body = Base64.getEncoder().encodeToString(text.toByteArray())
        return if (nip04) "$body?iv=AAAA" else "v2:$body"
    }

    private fun open(text: String, nip04: Boolean): String? = runCatching {
        String(Base64.getDecoder().decode(if (nip04) text.substringBefore('?') else text.removePrefix("v2:")))
    }.getOrNull()

    private val schemes = mutableListOf<Boolean>()

    private fun unblock(
        content: String,
        remove: List<String>,
        knownPrivate: Boolean = false,
        encrypt: (String, Boolean) -> String? = ::seal,
    ) = runBlocking {
        schemes.clear()
        ListMerge.removingPrivate(
            content, remove, knownPrivate,
            decrypt = { text, nip04 -> schemes += nip04; open(text, nip04) },
            encrypt = { text, nip04 -> schemes += nip04; encrypt(text, nip04) },
        )
    }

    private val privatePart = """[["p","aaa"],["p","bbb","wss://r.example/","pet"],["word","spoiler"],["e","thread1"]]"""

    @Test
    fun `unblock of a private-only person takes them out of the NIP-44 part`() {
        val result = unblock(seal(privatePart, false), listOf("AAA")) as ListMerge.PrivateEdit.Done
        assertEquals(false, MuteList.isNip04(result.content))
        assertEquals(
            listOf(listOf("p", "bbb", "wss://r.example/", "pet"), listOf("word", "spoiler"), listOf("e", "thread1")),
            MuteList.privateTags(open(result.content, false)!!),
        )
        assertEquals("opened, encrypted, opened again to check", listOf(false, false, false), schemes)
    }

    @Test
    fun `unblock keeps a NIP-04 part NIP-04`() {
        val result = unblock(seal(privatePart, true), listOf("bbb")) as ListMerge.PrivateEdit.Done
        assertEquals(true, MuteList.isNip04(result.content))
        assertEquals(
            listOf(listOf("p", "aaa"), listOf("word", "spoiler"), listOf("e", "thread1")),
            MuteList.privateTags(open(result.content, true)!!),
        )
        assertEquals(listOf(true, true, true), schemes)
    }

    @Test
    fun `unblock of someone not in the private part leaves it as it is`() {
        val sealed = seal(privatePart, false)
        // A thread with the same value as the person is not a person.
        assertEquals(ListMerge.PrivateEdit.Done(sealed), unblock(sealed, listOf("ccc", "thread1")))
        assertEquals("opened, never encrypted again", listOf(false), schemes)
    }

    @Test
    fun `block and empty content never open the private part`() {
        assertEquals(ListMerge.PrivateEdit.Done(seal(privatePart, false)), unblock(seal(privatePart, false), emptyList(), knownPrivate = true))
        assertEquals(emptyList<Boolean>(), schemes)
        assertEquals(ListMerge.PrivateEdit.Done(""), unblock("", listOf("aaa"), knownPrivate = true))
        assertEquals(emptyList<Boolean>(), schemes)
    }

    @Test
    fun `a private part this device can't open is kept only when they aren't known private`() {
        assertEquals(ListMerge.PrivateEdit.Done("v2:not base64!"), unblock("v2:not base64!", listOf("aaa")))
        // A signer that won't decrypt (Amber without silent permission, a
        // bunker that's away) must not publish a list that re-blocks them.
        assertEquals(ListMerge.PrivateEdit.Failed, unblock("v2:not base64!", listOf("aaa"), knownPrivate = true))
    }

    @Test
    fun `a private part a rewrite would lose fails when reading it back still blocks them`() {
        // Reading skips the null and the object; writing can't keep them.
        val odd = seal("""[["p","aaa",null],["p","bbb",1],{"x":"y"}]""", false)
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(odd, listOf("aaa")))
        assertEquals("opened, never encrypted again", listOf(false), schemes)
        assertTrue(MuteList.privateTags(open(odd, false)!!)!!.contains(listOf("p", "aaa")))
        // Someone who isn't in it: nothing to rewrite, the part is kept.
        assertEquals(ListMerge.PrivateEdit.Done(odd), unblock(odd, listOf("ccc")))
        assertNull(ListMerge.privateRemoved("""{"p":"aaa"}""", listOf("aaa")))
    }

    @Test
    fun `unblock is not published when the private part can't be encrypted again`() {
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, false), listOf("aaa")) { _, _ -> null })
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, false), listOf("aaa")) { _, _ -> error("signer") })
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, false), listOf("aaa")) { _, _ -> "" })
    }

    @Test
    fun `a signer that echoes the plaintext is not published`() {
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, false), listOf("aaa")) { text, _ -> text })
    }

    @Test
    fun `a signer that switches scheme is not published`() {
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, false), listOf("aaa")) { text, _ -> seal(text, true) })
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, true), listOf("aaa")) { text, _ -> seal(text, false) })
    }

    @Test
    fun `a signer that encrypts something else is not published`() {
        // Another key or account: this device opens it to other text, or not at all.
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, false), listOf("aaa")) { _, nip04 -> seal("""[["p","zzz"]]""", nip04) })
        assertEquals(ListMerge.PrivateEdit.Failed, unblock(seal(privatePart, false), listOf("aaa")) { _, _ -> "v2:not base64!" })
    }
}
